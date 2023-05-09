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
  _folders = {
    for f in local.hierarchy_files : dirname(f) => yamldecode(
      file("${coalesce(var.factories_config.projects_path, "-")}/${f}")
    )
  }
  folders = {
    for key, data in local._folders : key => merge(data, {
      key        = key
      level      = length(split("/", key))
      parent_key = replace(key, "/\\/[^\\/]+$/", "")
    })
  }
  hierarchy = merge(
    { for k, v in module.hierarchy-folder-lvl-2 : k => v.id },
    { for k, v in module.hierarchy-folder-lvl-3 : k => v.id },
    { for k, v in module.hierarchy-folder-lvl-4 : k => v.id },
  )
  hierarchy_parents = merge(var.folder_ids, local.hierarchy)
}

module "hierarchy-folder-lvl-2" {
  source       = "../../../../modules/folder"
  for_each     = { for k, v in local.folders : k => v if v.level == 2 }
  parent       = var.folder_ids[each.value.parent_key]
  name         = each.value.name
  iam          = lookup(each.value, "iam", {})
  group_iam    = lookup(each.value, "group_iam", {})
  org_policies = lookup(each.value, "org_policies", {})
  tag_bindings = lookup(each.value, "tag_bindings", {})
}

module "hierarchy-folder-lvl-3" {
  source       = "../../../../modules/folder"
  for_each     = { for k, v in local.folders : k => v if v.level == 3 }
  parent       = module.hierarchy-folder-lvl-2[each.value.parent_key].id
  name         = each.value.name
  iam          = lookup(each.value, "iam", {})
  group_iam    = lookup(each.value, "group_iam", {})
  org_policies = lookup(each.value, "org_policies", {})
  tag_bindings = lookup(each.value, "tag_bindings", {})
}

module "hierarchy-folder-lvl-4" {
  source       = "../../../../modules/folder"
  for_each     = { for k, v in local.folders : k => v if v.level == 4 }
  parent       = module.hierarchy-folder-lvl-3[each.value.parent_key].id
  name         = each.value.name
  iam          = lookup(each.value, "iam", {})
  group_iam    = lookup(each.value, "group_iam", {})
  org_policies = lookup(each.value, "org_policies", {})
  tag_bindings = lookup(each.value, "tag_bindings", {})
}