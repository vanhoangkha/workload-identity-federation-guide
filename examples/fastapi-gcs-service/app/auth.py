"""
WIF authentication: EKS IRSA → Hub Role → GCP WIF → GCS client.

Environment variables required:
  HUB_ROLE_ARN   - ARN of the hub role to assume
  WIF_AUDIENCE   - GCP WIF pool/provider audience
  GCP_SA_EMAIL   - GCP Service Account email
  GCP_PROJECT_ID - GCP project ID
  AWS_REGION     - AWS region (default: us-east-1)
"""
import os
import logging

import boto3
from google.auth import aws as google_aws
from google.auth.transport.requests import Request
from google.cloud import storage

logger = logging.getLogger(__name__)

HUB_ROLE_ARN = os.environ["HUB_ROLE_ARN"]
WIF_AUDIENCE = os.environ["WIF_AUDIENCE"]
GCP_SA_EMAIL = os.environ["GCP_SA_EMAIL"]
GCP_PROJECT_ID = os.environ["GCP_PROJECT_ID"]
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")


def _assume_hub_role() -> dict:
    """
    Assume the hub role using IRSA-injected credentials.
    boto3 automatically picks up IRSA tokens from the projected volume.
    """
    sts = boto3.client("sts", region_name=AWS_REGION)
    resp = sts.assume_role(
        RoleArn=HUB_ROLE_ARN,
        RoleSessionName="eks-gcs-session",
        DurationSeconds=3600,
    )
    logger.info("Assumed hub role: %s", HUB_ROLE_ARN)
    return resp["Credentials"]


def get_gcs_client() -> storage.Client:
    """
    Build a GCS client via hub-role credentials exchanged through GCP WIF.

    Flow:
      1. Assume hub role → temporary AWS credentials
      2. Set env vars so google.auth.aws reads them (not IMDS)
      3. google.auth.aws signs GetCallerIdentity as the hub role
      4. GCP STS verifies signature → federated token
      5. Federated token impersonates GCP SA → access token
    """
    creds = _assume_hub_role()

    os.environ["AWS_ACCESS_KEY_ID"] = creds["AccessKeyId"]
    os.environ["AWS_SECRET_ACCESS_KEY"] = creds["SecretAccessKey"]
    os.environ["AWS_SESSION_TOKEN"] = creds["SessionToken"]
    os.environ["AWS_REGION"] = AWS_REGION
    os.environ["AWS_DEFAULT_REGION"] = AWS_REGION

    wif_config = {
        "type": "external_account",
        "audience": WIF_AUDIENCE,
        "subject_token_type": "urn:ietf:params:aws:token-type:aws4_request",
        "service_account_impersonation_url": (
            f"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/"
            f"{GCP_SA_EMAIL}:generateAccessToken"
        ),
        "token_url": "https://sts.googleapis.com/v1/token",
        "credential_source": {
            "environment_id": "aws1",
            "regional_cred_verification_url": (
                "https://sts.{region}.amazonaws.com"
                "?Action=GetCallerIdentity&Version=2011-06-15"
            ),
        },
    }

    gcp_creds = google_aws.Credentials.from_info(
        wif_config,
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )
    gcp_creds.refresh(Request())
    logger.info("GCP WIF token obtained for SA: %s", GCP_SA_EMAIL)

    return storage.Client(credentials=gcp_creds, project=GCP_PROJECT_ID)
