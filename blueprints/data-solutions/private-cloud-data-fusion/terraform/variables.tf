# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


variable "project_id" {
  description = "GCP Project ID"
  default     = null
}

variable "region" {
  type        = string
  description = "GCP region"
  default     = "us-central1"
}

variable "network_name" {
  type        = string
  description = "VPC name"
  default     = "vpc-data"
}

variable "servicenetworking_cidr" {
  type        = string
  description = "Service Networking CIDR"
  default     = "10.200.0.0/22"
}

variable "subnetwork_cidr" {
  type        = string
  description = "GCE subnet CIDR"
  default     = "10.0.1.0/24"
}

variable "cdf_instance_name" {
  type        = string
  description = "Cloud Data Fusion instance name"
  default     = "private-cdf"
}

variable "cdf_cidr" {
  type        = string
  description = "Cloud Data Fusion network CIDR"
  default     = "10.200.4.0/22"
}

variable "cdf_type" {
  type        = string
  description = "Cloud Data Fusion instance type"
  default     = "DEVELOPER"
}

variable "db_password" {
  type        = string
  description = "Database default password"
  default     = "supersecret"
}

variable "resource_labels" {
  type        = map(string)
  description = "Resource labels"
  default = {
    deployed_by = "cloudbuild"
    env         = "sandbox"
    repo        = "cloud-foundation-fabric"
    terraform   = "true"
  }
}