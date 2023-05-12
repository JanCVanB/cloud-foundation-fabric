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
  _vpc_sc_landing_bridges = setproduct(["landing"], ["dev", "prod"])
  # define dry run spec at file level for convenience
  vpc_sc_explicit_dry_run_spec = true
  # compute perimeter bridge resources (projects)
  vpc_sc_perimeter_resources = {
    for k, v in var.vpc_sc_perimeters : k => sort(toset(flatten([
      v.resources,
      [for f in v.folder_ids : local._vpc_sc_resources_projects_by_folders[f]],
      [for p in v.project_ids : local._vpc_sc_resources_projects_by_ids[p]]
    ])))
  }
  # compute the number of projects in each perimeter to detect which to create
  vpc_sc_counts = {
    for k, v in local.vpc_sc_perimeter_resources : k => length(v)
  }
  vpc_sc_perimeters_spec_status = {
    for k, v in var.vpc_sc_perimeters : k => merge([
      v,
      {
        resources               = local.vpc_sc_perimeter_resources[k]
        restricted_services     = local._vpc_sc_restricted_services
        vpc_accessible_services = local._vpc_sc_vpc_accessible_services
        project_ids             = null
        folder_ids              = null
      },
    ]...)
  }
  vpc_sc_bridge_resources = {
    for p in local._vpc_sc_landing_bridges :
    "${p.0}_to_${p.1}" => sort(toset(flatten([
      local.vpc_sc_perimeter_resources[p.0],
      local.vpc_sc_perimeter_resources[p.1],
    ])))
  }
  vpc_sc_egress_policies = {
    for k, v in var.vpc_sc_egress_policies :
    k => {
      from = v.from
      to = merge([
        v.to,
        {
          resources = sort(toset(flatten([
            v.to.resources,
            [for f in v.to.folder_ids : local._vpc_sc_resources_projects_by_folders[f]],
            [for p in v.to.project_ids : local._vpc_sc_resources_projects_by_ids[p]],
          ])))
          project_ids = null
          folder_ids  = null
        }
      ]...)
    }
  }
  vpc_sc_ingress_policies = {
    for k, v in var.vpc_sc_ingress_policies :
    k => {
      from = merge([
        v.from,
        {
          resources = sort(toset(flatten([
            v.from.resources,
            [for f in v.from.folder_ids : local._vpc_sc_resources_projects_by_folders[f]],
            [for p in v.from.project_ids : local._vpc_sc_resources_projects_by_ids[p]],
          ])))
          project_ids = null
          folder_ids  = null
        }
      ]...)
      to = merge([
        v.to,
        {
          resources = sort(toset(flatten([
            v.to.resources,
            [for f in v.to.folder_ids : local._vpc_sc_resources_projects_by_folders[f]],
            [for p in v.to.project_ids : local._vpc_sc_resources_projects_by_ids[p]],
          ])))
          project_ids = null
          folder_ids  = null
        }
      ]...)
    }
  }
}

data "google_projects" "project_by_ids" {
  for_each = local._vpc_sc_resources_lookup_projects
  filter   = "(${join(" OR ", formatlist("id=%s", each.value))}) AND lifecycleState:ACTIVE"
}

data "google_projects" "project_by_folders" {
  for_each = local._vpc_sc_resources_lookup_folders
  filter   = "parent.type=folder parent.id=${each.value} AND lifecycleState:ACTIVE"
}

module "vpc-sc" {
  source = "../modules/vpc-sc"
  # only enable if we have projects defined for perimeters
  count         = anytrue([for k, v in local.vpc_sc_counts : v > 0]) ? 1 : 0
  access_policy = null
  access_policy_create = {
    parent = "organizations/${var.organization.id}"
    title  = "default"
  }
  access_levels    = var.vpc_sc_access_levels
  egress_policies  = local.vpc_sc_egress_policies
  ingress_policies = local.vpc_sc_ingress_policies
  # bridge perimeters
  service_perimeters_bridge = merge(
    [
      for p in local._vpc_sc_landing_bridges :
      # landing to other perimtere, only we have projects in landing and corresponding perimeters
      local.vpc_sc_counts[p.0] * local.vpc_sc_counts[p.1] == 0 ? {} : {
        "${p.0}_to_${p.1}" = {
          spec_resources = (
            local.vpc_sc_explicit_dry_run_spec
            ? local.vpc_sc_bridge_resources["${p.0}_to_${p.1}"]
            : null
          )
          status_resources = (
            local.vpc_sc_explicit_dry_run_spec
            ? null
            : local.vpc_sc_bridge_resources["${p.0}_to_${p.1}"]
          )
          use_explicit_dry_run_spec = local.vpc_sc_explicit_dry_run_spec
        }
      }
  ]...)
  # regular type perimeters
  service_perimeters_regular = merge([
    # if we have projects in var.vpc_sc_perimeter_projects.dev
    for k, v in local.vpc_sc_perimeters_spec_status : local.vpc_sc_counts[k] == 0 ? {} : {
      "${k}" = {
        spec = (
          local.vpc_sc_explicit_dry_run_spec
          ? local.vpc_sc_perimeters_spec_status[k]
          : null
        )
        status = (
          local.vpc_sc_explicit_dry_run_spec
          ? null
          : local.vpc_sc_perimeters_spec_status[k]
        )
        use_explicit_dry_run_spec = local.vpc_sc_explicit_dry_run_spec
      }
    }
  ]...)
}
