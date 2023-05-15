/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  _vpc_sc_vpc_accessible_services = null
  _vpc_sc_restricted_services = yamldecode(
    file("${path.module}/vpc-sc-restricted-services.yaml")
  )
  _vpc_sc_resources_lookup_folders = { for i, v in toset(flatten([
    [for v in var.vpc_sc_perimeters : v.folder_ids],
    [for v in var.vpc_sc_egress_policies : v.to.folder_ids],
    [for v in var.vpc_sc_ingress_policies : v.to.folder_ids],
    [for v in var.vpc_sc_ingress_policies : v.from.folder_ids],
  ])) : i => v }
  _vpc_sc_resources_lookup_projects = { for i, v in chunklist(sort(toset(flatten([
    [for v in var.vpc_sc_perimeters : v.project_ids],
    [for v in var.vpc_sc_egress_policies : v.to.project_ids],
    [for v in var.vpc_sc_ingress_policies : v.to.project_ids],
    [for v in var.vpc_sc_ingress_policies : v.from.project_ids],
  ]))), 50) : i => v }
  _vpc_sc_resources_projects_by_folders = {
    for k in local._vpc_sc_resources_lookup_folders :
    k => formatlist("projects/%s", data.google_projects.project_by_folders[k].projects[*].number)
  }
  _vpc_sc_resources_projects_by_ids = {
    for k in flatten(values(data.google_projects.project_by_ids)[*].projects) :
    k.project_id => "projects/${k.number}"
  }
  # compute perimeter resources (projects)
  _vpc_sc_perimeter_resources = {
    for k, v in var.vpc_sc_perimeters : k => sort(toset(flatten([
      v.resources,
      [for f in v.folder_ids : local._vpc_sc_resources_projects_by_folders[f]],
      [for p in v.project_ids : local._vpc_sc_resources_projects_by_ids[p]]
    ])))
  }
  # compute the number of projects in each perimeter to detect which to create
  _vpc_sc_counts = {
    for k, v in local._vpc_sc_perimeter_resources : k => length(v)
  }
}

data "google_projects" "project_by_ids" {
  for_each = local._vpc_sc_resources_lookup_projects
  filter   = "(${join(" OR ", formatlist("id=%s", each.value))}) AND lifecycleState=ACTIVE"
}

data "google_projects" "project_by_folders" {
  for_each = local._vpc_sc_resources_lookup_folders
  filter   = "parent.type=folder parent.id=${each.value} AND lifecycleState=ACTIVE"
}
