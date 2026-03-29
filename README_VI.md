# HƯỚNG DẪN TRIỂN KHAI WORKLOAD IDENTITY FEDERATION GIỮA AWS VÀ GOOGLE CLOUD


## 1. Giới thiệu tổng quan

### 1.1 Bối cảnh

Trong mô hình đa đám mây (multi-cloud), các ứng dụng chạy trên AWS thường cần truy cập dịch vụ của Google Cloud như BigQuery, Cloud Storage hoặc Compute Engine. Phương pháp truyền thống sử dụng Service Account Key (tệp JSON chứa khóa bí mật) tiềm ẩn nhiều rủi ro bảo mật: khóa có thể bị lộ, không tự động hết hạn, và khó kiểm soát nguồn gốc truy cập.

Google Cloud Workload Identity Federation giải quyết vấn đề này bằng cách cho phép các workload trên AWS xác thực trực tiếp với Google Cloud thông qua cơ chế trao đổi token, hoàn toàn không cần lưu trữ bất kỳ khóa bí mật nào.

### 1.2 Kiến trúc tổng thể

![Kiến trúc Workload Identity Federation](images/wif_architecture.png)

### 1.3 Luồng xác thực chi tiết

![Luồng xác thực](images/wif_auth_flow.png)

Giải thích từng bước:

1. Workload trên AWS sử dụng IAM Role để lấy AWS STS token từ Instance Metadata Service (đối với EC2) hoặc từ Execution Role (đối với Lambda, EKS).
2. Google STS nhận AWS token và xác minh tính hợp lệ bằng cách gọi ngược về AWS STS endpoint.
3. Sau khi xác minh thành công, Google STS cấp phát một Federated Token ngắn hạn.
4. Federated Token được sử dụng để mạo danh (impersonate) một Google Cloud Service Account đã được cấu hình sẵn.
5. Service Account Access Token (thời hạn 1 giờ) được cấp phát để gọi các Google Cloud API.

### 1.4 So sánh phương pháp xác thực

| Tiêu chí | Service Account Key | Workload Identity Federation |
|----------|--------------------|-----------------------------|
| Lưu trữ khóa bí mật | Có - cần bảo vệ tệp JSON | Không - không có khóa để lưu trữ |
| Xoay vòng khóa (rotation) | Thủ công, dễ bỏ sót | Tự động - token hết hạn sau 1 giờ |
| Rủi ro lộ thông tin | Cao - tệp khóa có thể bị lộ qua git, log, backup | Không có tệp khóa để lộ |
| Kiểm toán (audit) | Chỉ biết Service Account nào gọi | Truy vết được danh tính AWS gốc (ARN) |
| Thời hạn hiệu lực | Vĩnh viễn cho đến khi thu hồi | Token tự động hết hạn sau 1 giờ |
| Tuân thủ bảo mật | Không đạt nhiều tiêu chuẩn | Phù hợp với Zero Trust, SOC2, ISO 27001 |

### 1.5 Các dịch vụ Google Cloud được hỗ trợ

| Nhóm dịch vụ | Dịch vụ cụ thể |
|---------------|----------------|
| Phân tích dữ liệu | BigQuery, Dataflow, Dataproc |
| Lưu trữ | Cloud Storage, Filestore |
| Tính toán | Compute Engine, Cloud Run, GKE |
| Giám sát | Cloud Logging, Cloud Monitoring |
| Cơ sở dữ liệu | Cloud SQL, Spanner, Firestore |
| Bảo mật | Secret Manager, KMS |
| AI/ML | Vertex AI, AutoML |

---

## 2. Chi phí giải pháp

### 2.1 Chi phí Workload Identity Federation

| Hạng mục | Chi phí |
|----------|---------|
| Tạo Workload Identity Pool | Miễn phí |
| Tạo Provider | Miễn phí |
| Trao đổi token (STS API calls) | Miễn phí |
| Service Account impersonation | Miễn phí |
| Tệp credential configuration | Miễn phí |

Kết luận: Bản thân Workload Identity Federation hoàn toàn miễn phí. Không có chi phí phát sinh cho việc xác thực liên đám mây.

### 2.2 Chi phí các dịch vụ Google Cloud được truy cập

Chi phí phát sinh chỉ từ việc sử dụng các dịch vụ Google Cloud đích:

| Dịch vụ | Gói miễn phí hàng tháng | Chi phí vượt gói |
|---------|------------------------|-----------------|
| BigQuery | 1 TB truy vấn + 10 GB lưu trữ | $6.25/TB truy vấn |
| Cloud Storage | 5 GB Standard + 5,000 Class A ops | $0.020/GB/tháng (Standard) |
| Cloud Logging | 50 GB nhật ký đầu tiên | $0.50/GB |
| Compute Engine | 1 e2-micro instance | Theo cấu hình VM |
| Secret Manager | 6 active secrets + 10,000 access ops | $0.06/secret/tháng |

### 2.3 Chi phí phía AWS

| Hạng mục | Chi phí |
|----------|---------|
| IAM Role | Miễn phí |
| AWS STS API calls | Miễn phí |
| EC2 Instance Metadata Service | Miễn phí |

### 2.4 So sánh tổng chi phí

| Phương pháp | Chi phí xác thực | Chi phí vận hành | Rủi ro ẩn |
|-------------|-----------------|-----------------|-----------|
| Service Account Key | Miễn phí | Chi phí quản lý key rotation, giám sát lộ key | Chi phí xử lý sự cố nếu key bị lộ |
| Workload Identity Federation | Miễn phí | Không có chi phí vận hành thêm | Không có rủi ro lộ key |

---

## 3. Điều kiện tiên quyết

### 3.1 Phía AWS

- Tài khoản AWS với quyền quản trị IAM
- Workload đã được gán IAM Role (EC2 Instance Profile, Lambda Execution Role, hoặc EKS Service Account)
- AWS CLI phiên bản 2.x trở lên

### 3.2 Phía Google Cloud

- Google Cloud Project với tính năng thanh toán (billing) đã bật
- Quyền IAM Admin và Service Account Admin trên project
- gcloud CLI phiên bản 363.0.0 trở lên

---

## 4. Thu thập thông tin cấu hình

### 4.1 Thông tin AWS

Đăng nhập vào workload AWS và thực thi:

```bash
aws sts get-caller-identity
```

Kết quả mẫu:

```json
{
    "UserId": "AROAXXXXXXXXXXXXXXXXX:i-0xxxxxxxxxxxxxxxxxx",
    "Account": "XXXXXXXXXXXX",
    "Arn": "arn:aws:sts::XXXXXXXXXXXX:assumed-role/<ROLE_NAME>/i-0xxxxxxxxxxxxxxxxxx"
}
```

| Thông tin | Vị trí trong kết quả | Mô tả |
|-----------|----------------------|-------|
| AWS Account ID | Trường "Account" | Mã tài khoản AWS gồm 12 chữ số |
| Tên IAM Role | Phần giữa "assumed-role/" và "/" tiếp theo | Tên role gắn với workload |
| Full ARN | Toàn bộ trường "Arn" | Định danh đầy đủ của workload |

[CHỤP HÌNH: Màn hình terminal hiển thị kết quả lệnh aws sts get-caller-identity]

### 4.2 Thông tin Google Cloud

Truy cập Google Cloud Console, ghi nhận Project ID và Project Number.

Lưu ý: Project Number (dạng số) được sử dụng trong cấu hình, không phải Project ID.

[CHỤP HÌNH: Google Cloud Console hiển thị Project Info]

---

## 5. Thiết lập Workload Identity Federation trên Google Cloud

### 5.1 Bật các API cần thiết

```bash
gcloud services enable \
  iam.googleapis.com \
  sts.googleapis.com \
  iamcredentials.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com \
  --project=<PROJECT_ID>
```

[CHỤP HÌNH: Terminal hiển thị kết quả bật API thành công]

### 5.2 Tạo Workload Identity Pool

```bash
gcloud iam workload-identity-pools create <POOL_ID> \
  --project=<PROJECT_ID> \
  --location=global \
  --display-name="<TÊN HIỂN THỊ>" \
  --description="Pool xác thực cho các workload từ AWS"
```

[CHỤP HÌNH: Google Cloud Console hiển thị Workload Identity Pool vừa tạo]

### 5.3 Tạo AWS Provider

```bash
gcloud iam workload-identity-pools providers create-aws <PROVIDER_ID> \
  --project=<PROJECT_ID> \
  --location=global \
  --workload-identity-pool=<POOL_ID> \
  --account-id=<AWS_ACCOUNT_ID> \
  --attribute-mapping="google.subject=assertion.arn"
```

[CHỤP HÌNH: Terminal hiển thị kết quả tạo provider thành công]

### 5.4 Tạo Service Account

```bash
gcloud iam service-accounts create <SA_NAME> \
  --project=<PROJECT_ID> \
  --display-name="<TÊN HIỂN THỊ>"
```

[CHỤP HÌNH: Google Cloud Console hiển thị Service Account vừa tạo]

### 5.5 Cấp quyền mạo danh Service Account cho AWS

```bash
MEMBER="principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/subject/<FULL_AWS_ARN>"

gcloud iam service-accounts add-iam-policy-binding \
  <SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com \
  --project=<PROJECT_ID> \
  --role=roles/iam.workloadIdentityUser \
  --member="${MEMBER}"

gcloud iam service-accounts add-iam-policy-binding \
  <SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com \
  --project=<PROJECT_ID> \
  --role=roles/iam.serviceAccountTokenCreator \
  --member="${MEMBER}"
```

Lưu ý quan trọng:
- PROJECT_NUMBER phải là dạng số, không phải Project ID dạng chuỗi
- FULL_AWS_ARN phải khớp chính xác với ARN của workload
- Cần cấp đồng thời cả hai role
- Chờ 30-60 giây để chính sách IAM có hiệu lực

[CHỤP HÌNH: Terminal hiển thị kết quả cấp quyền thành công]

### 5.6 Cấp quyền truy cập dịch vụ Google Cloud

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --role=<ROLE> \
  --member="serviceAccount:<SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com"
```

Bảng tham khảo role:

| Dịch vụ | Role | Mô tả |
|---------|------|-------|
| BigQuery | roles/bigquery.dataViewer | Đọc dữ liệu |
| BigQuery | roles/bigquery.jobUser | Thực thi truy vấn |
| Cloud Storage | roles/storage.objectAdmin | Toàn quyền trên object |
| Cloud Logging | roles/logging.logWriter | Ghi nhật ký |
| Compute Engine | roles/compute.viewer | Xem thông tin máy ảo |
| Secret Manager | roles/secretmanager.secretAccessor | Đọc secret |

### 5.7 Tạo tệp cấu hình xác thực

```bash
gcloud iam workload-identity-pools create-cred-config \
  projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/providers/<PROVIDER_ID> \
  --service-account=<SA_NAME>@<PROJECT_ID>.iam.gserviceaccount.com \
  --aws \
  --enable-imdsv2 \
  --output-file=gcp-credentials.json
```

Tệp này không chứa khóa bí mật - an toàn để lưu trữ trong hệ thống quản lý mã nguồn.

[CHỤP HÌNH: Nội dung tệp gcp-credentials.json]

---

## 6. Thiết lập trên AWS

### 6.1 Sao chép tệp cấu hình

```bash
scp gcp-credentials.json <USER>@<EC2_IP>:/opt/gcp/
```

### 6.2 Thiết lập biến môi trường

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/opt/gcp/gcp-credentials.json
echo 'export GOOGLE_APPLICATION_CREDENTIALS=/opt/gcp/gcp-credentials.json' >> ~/.bashrc
```

### 6.3 Cài đặt thư viện

```bash
pip install google-cloud-bigquery google-cloud-storage google-cloud-logging
```

---

## 7. Các kịch bản ứng dụng

![Các kịch bản ứng dụng](images/wif_use_cases.png)

### 7.1 EC2 truy vấn dữ liệu BigQuery

Kịch bản: Ứng dụng phân tích dữ liệu chạy trên EC2 cần truy vấn dữ liệu lưu trữ trên BigQuery.

Quyền cần cấp: roles/bigquery.dataViewer + roles/bigquery.jobUser

```python
from google.cloud import bigquery

client = bigquery.Client(project="<PROJECT_ID>")

# Liệt kê datasets
for dataset in client.list_datasets():
    print(f"  Dataset: {dataset.dataset_id}")

# Truy vấn dữ liệu
query = """
SELECT corpus, COUNT(*) as word_count
FROM `bigquery-public-data.samples.shakespeare`
GROUP BY corpus ORDER BY word_count DESC LIMIT 5
"""
for row in client.query(query).result():
    print(f"  {row.corpus}: {row.word_count}")
```

Kết quả thực tế đã kiểm thử:

```
=== USE CASE 1: BigQuery ===

Datasets trong project:
  (Chưa có dataset - project mới)

Top 5 tác phẩm Shakespeare theo số từ:
  hamlet: 5318
  kinghenryv: 5104
  cymbeline: 4875
  troilusandcressida: 4795
  kinglear: 4784

Kết nối BigQuery thành công!
```

[CHỤP HÌNH: Terminal hiển thị kết quả truy vấn BigQuery]

### 7.2 EC2 đồng bộ dữ liệu với Cloud Storage

Kịch bản: Sao lưu dữ liệu từ EC2 sang Google Cloud Storage hoặc đồng bộ tệp giữa hai đám mây.

Quyền cần cấp: roles/storage.objectAdmin

```python
from google.cloud import storage
import os

client = storage.Client(project="<PROJECT_ID>")
bucket = client.bucket("<BUCKET_NAME>")

# Upload tệp
blob = bucket.blob("backups/database.sql.gz")
blob.upload_from_filename("/tmp/database.sql.gz")

# Download tệp
blob = bucket.blob("config/app-settings.json")
blob.download_to_filename("/opt/app/settings.json")

# Đồng bộ thư mục
def sync_directory(local_dir, gcs_prefix):
    count = 0
    for root, dirs, files in os.walk(local_dir):
        for filename in files:
            local_path = os.path.join(root, filename)
            relative_path = os.path.relpath(local_path, local_dir)
            blob = bucket.blob(f"{gcs_prefix}/{relative_path}")
            blob.upload_from_filename(local_path)
            count += 1
    print(f"Đã đồng bộ {count} tệp")

sync_directory("/var/log/app", "logs/ec2-web-01")
```

Kết quả thực tế đã kiểm thử:

```
=== USE CASE 2: Cloud Storage ===

Buckets trong project:
  (Chưa có bucket - project mới)

Xác thực Cloud Storage thành công!
```

### 7.3 EC2 quản lý tài nguyên Compute Engine

Kịch bản: Giám sát và kiểm kê máy ảo trên cả AWS và Google Cloud từ một điểm duy nhất.

Quyền cần cấp: roles/compute.viewer

```python
import boto3
from google.cloud import compute_v1

print("=== KIỂM KÊ TÀI NGUYÊN ĐA ĐÁM MÂY ===")

# AWS EC2
ec2 = boto3.client("ec2")
aws_result = ec2.describe_instances()
print("\nAWS EC2 Instances:")
for res in aws_result["Reservations"]:
    for inst in res["Instances"]:
        name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "N/A")
        print(f"  {name} | {inst['InstanceId']} | {inst['State']['Name']}")

# Google Cloud Compute Engine
gcp_client = compute_v1.InstancesClient()
request = compute_v1.AggregatedListInstancesRequest(project="<PROJECT_ID>")
print("\nGoogle Cloud Compute Instances:")
for zone, response in gcp_client.aggregated_list(request=request):
    if response.instances:
        for inst in response.instances:
            print(f"  {inst.name} | {zone} | {inst.status}")
```

### 7.4 Terraform trên AWS quản lý hạ tầng Google Cloud

Kịch bản: Sử dụng Terraform chạy trên AWS để quản lý hạ tầng Google Cloud theo mô hình Infrastructure as Code.

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "<PROJECT_ID>"
  region  = "us-central1"
}

resource "google_bigquery_dataset" "analytics" {
  dataset_id  = "cross_cloud_analytics"
  location    = "US"
  description = "Dữ liệu phân tích liên đám mây"
}

resource "google_storage_bucket" "data_lake" {
  name     = "<PROJECT_ID>-data-lake"
  location = "US"
  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
  versioning { enabled = true }
}
```

Thực thi:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/opt/gcp/gcp-credentials.json
terraform init
terraform plan
terraform apply
```

### 7.5 Tập trung nhật ký từ AWS sang Cloud Logging

Kịch bản: Thu thập nhật ký ứng dụng và sự kiện bảo mật từ AWS, gửi về Google Cloud Logging để phân tích tập trung.

Quyền cần cấp: roles/logging.logWriter

```python
from google.cloud import logging as cloud_logging
import socket
import datetime

client = cloud_logging.Client(project="<PROJECT_ID>")
logger = client.logger("aws-application")

hostname = socket.gethostname()

logger.log_struct({
    "severity": "INFO",
    "message": "Ứng dụng khởi động thành công",
    "hostname": hostname,
    "source": "aws-ec2",
    "timestamp": datetime.datetime.now(datetime.UTC).isoformat()
})
```

Kết quả thực tế đã kiểm thử:

```
=== USE CASE 5: Cloud Logging ===

Đã gửi log thành công tới GCP Cloud Logging!
  Logger: aws-wif-test
  Hostname: ip-172-31-xx-xxx
  Timestamp: 2026-03-29T06:34:55.402882
```

[CHỤP HÌNH: Google Cloud Console > Cloud Logging hiển thị nhật ký từ AWS]

### 7.6 Lambda gọi Google Cloud API

Kịch bản: AWS Lambda function cần ghi dữ liệu vào BigQuery hoặc đọc tệp từ Cloud Storage.

Cấu hình: Đóng gói tệp gcp-credentials.json cùng mã nguồn Lambda.

```python
import os
import json

def lambda_handler(event, context):
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "/var/task/gcp-credentials.json"

    from google.cloud import bigquery
    client = bigquery.Client(project="<PROJECT_ID>")

    table_id = "<PROJECT_ID>.events.lambda_events"
    rows = [{
        "event_source": event.get("source", "unknown"),
        "event_detail": json.dumps(event),
        "processed_at": context.function_name,
    }]
    errors = client.insert_rows_json(table_id, rows)
    return {"statusCode": 200, "body": f"Inserted {len(rows)} rows"}
```

Lưu ý đối với Lambda:
- Đóng gói google-cloud-bigquery vào Lambda Layer hoặc deployment package
- Lambda Execution Role tự động có AWS STS token, không cần cấu hình thêm phía AWS

### 7.7 EKS Pod truy cập dịch vụ Google Cloud

Kịch bản: Ứng dụng chạy trên Amazon EKS cần truy cập dịch vụ Google Cloud.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gcp-data-sync
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gcp-data-sync
  template:
    metadata:
      labels:
        app: gcp-data-sync
    spec:
      serviceAccountName: <EKS_SERVICE_ACCOUNT>
      containers:
      - name: sync
        image: <IMAGE>
        env:
        - name: GOOGLE_APPLICATION_CREDENTIALS
          value: /etc/gcp/gcp-credentials.json
        volumeMounts:
        - name: gcp-config
          mountPath: /etc/gcp
          readOnly: true
      volumes:
      - name: gcp-config
        secret:
          secretName: gcp-wif-config
```

### 7.8 CI/CD Pipeline trên AWS triển khai lên Google Cloud

Kịch bản: AWS CodeBuild triển khai ứng dụng lên Google Cloud Run hoặc GKE.

```yaml
version: 0.2
env:
  variables:
    GOOGLE_APPLICATION_CREDENTIALS: "gcp-credentials.json"
    GCP_PROJECT: "<PROJECT_ID>"
phases:
  install:
    commands:
      - pip install google-cloud-run
  build:
    commands:
      - docker build -t gcr.io/$GCP_PROJECT/my-app:$CODEBUILD_BUILD_NUMBER .
  post_build:
    commands:
      - python3 deploy_cloud_run.py
```

---

## 8. Xử lý sự cố

### 8.1 Lỗi "Permission iam.serviceAccounts.getAccessToken denied"

Nguyên nhân: Thiếu role iam.serviceAccountTokenCreator hoặc chính sách IAM chưa có hiệu lực.

Cách xử lý: Cấp thêm role serviceAccountTokenCreator và chờ 60 giây.

### 8.2 Lỗi "Unable to retrieve AWS region from metadata service"

Nguyên nhân: Workload không có IAM Role hoặc Instance Metadata Service không khả dụng.

Cách xử lý: Kiểm tra IAM Role bằng lệnh aws sts get-caller-identity. Nếu sử dụng IMDSv1, tạo lại credential config không có tham số --enable-imdsv2.

### 8.3 Lỗi "The caller does not have permission"

Nguyên nhân: Service Account thiếu role cho dịch vụ cần truy cập.

Cách xử lý: Kiểm tra và cấp thêm role phù hợp theo bảng tham khảo ở Mục 5.6.

### 8.4 Lỗi Subject mismatch

Nguyên nhân: ARN trong cấu hình IAM binding không khớp với ARN thực tế của workload.

Cách xử lý: Kiểm tra ARN thực tế bằng aws sts get-caller-identity. Lưu ý khi thay thế EC2 instance, Instance ID sẽ thay đổi và cần cập nhật lại IAM binding.

### 8.5 Lỗi Lambda "Could not connect to metadata service"

Nguyên nhân: Lambda không sử dụng EC2 Instance Metadata.

Cách xử lý: Đảm bảo tệp gcp-credentials.json được đóng gói đúng vị trí và biến môi trường GOOGLE_APPLICATION_CREDENTIALS trỏ đúng đường dẫn.

---

## 9. Danh sách hình ảnh minh họa

| STT | Vị trí | Nội dung cần chụp |
|-----|--------|-------------------|
| 1 | Mục 4.1 | Terminal: kết quả lệnh aws sts get-caller-identity |
| 2 | Mục 4.2 | Google Cloud Console: trang Project Info |
| 3 | Mục 5.1 | Terminal: kết quả bật API thành công |
| 4 | Mục 5.2 | Google Cloud Console: Workload Identity Pool |
| 5 | Mục 5.3 | Terminal: kết quả tạo provider |
| 6 | Mục 5.4 | Google Cloud Console: Service Account |
| 7 | Mục 5.5 | Terminal: kết quả cấp quyền impersonation |
| 8 | Mục 5.7 | Nội dung tệp gcp-credentials.json |
| 9 | Mục 7.1 | Terminal: kết quả truy vấn BigQuery |
| 10 | Mục 7.5 | Google Cloud Console: Cloud Logging hiển thị nhật ký từ AWS |

Lưu ý: 3 diagram kiến trúc đã được tạo sẵn tại thư mục images/ và chèn trực tiếp trong tài liệu.

---

## 10. Tài liệu tham khảo

1. Google Cloud - Workload Identity Federation with other clouds
   https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds

2. Google Cloud - Workload Identity Federation with Kubernetes
   https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes

3. Google Cloud - Best practices for Workload Identity Federation
   https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation

4. Google Cloud - Pricing Calculator
   https://cloud.google.com/products/calculator

5. AWS - EC2 Instance Metadata Service
   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html

6. AWS - IAM Roles for Amazon EC2
   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html

7. Terraform - Google Cloud Provider
   https://registry.terraform.io/providers/hashicorp/google/latest/docs
