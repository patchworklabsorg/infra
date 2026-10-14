# The GAM script already created these OUs and groups. Import them on the
# first plan so Terraform does not try to create them again.
#
# Steps:
#   1. Get the IDs (read-only):
#        gam select patchwork print orgs allfields
#        gam select patchwork print groups
#   2. Remove the leading "# " from the blocks you need and set each real ID.
#   3. Run the first plan. It must show imports and no creates for these items.
#   4. After the first apply, delete this file or leave the blocks in place.
#
# OU ID format: "id:<orgUnitId>" (the ID from `print orgs`, with the id: prefix).
# Group ID: the numeric group ID, not the email address.
#
# --- Org units ---
# import {
#   to = googleworkspace_org_unit.top["staff"]
#   id = "id:REPLACE_WITH_STAFF_OU_ID"
# }
# import {
#   to = googleworkspace_org_unit.top["board_only"]
#   id = "id:REPLACE_WITH_BOARD_ONLY_OU_ID"
# }
# import {
#   to = googleworkspace_org_unit.top["service_accounts"]
#   id = "id:REPLACE_WITH_SERVICE_ACCOUNTS_OU_ID"
# }
# import {
#   to = googleworkspace_org_unit.top["purgatory"]
#   id = "id:REPLACE_WITH_PURGATORY_OU_ID"
# }
# import {
#   to = googleworkspace_org_unit.top["sponsored_projects"]
#   id = "id:REPLACE_WITH_SPONSORED_PROJECTS_OU_ID"
# }
# import {
#   to = googleworkspace_org_unit.sponsored["hackboston"]
#   id = "id:REPLACE_WITH_HACKBOSTON_OU_ID"
# }
# import {
#   to = googleworkspace_org_unit.sponsored["hackathon_help"]
#   id = "id:REPLACE_WITH_HACKATHON_HELP_OU_ID"
# }
#
# --- Groups ---
# import {
#   to = googleworkspace_group.this["board"]
#   id = "REPLACE_WITH_BOARD_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["president"]
#   id = "REPLACE_WITH_PRESIDENT_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["treasurer"]
#   id = "REPLACE_WITH_TREASURER_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["secretary"]
#   id = "REPLACE_WITH_SECRETARY_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["ganymede_admins"]
#   id = "REPLACE_WITH_GANYMEDE_ADMINS_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["ganymede_users"]
#   id = "REPLACE_WITH_GANYMEDE_USERS_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["hackboston_organizers"]
#   id = "REPLACE_WITH_HACKBOSTON_ORGANIZERS_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["hackathon_help_organizers"]
#   id = "REPLACE_WITH_HACKATHON_HELP_ORGANIZERS_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["gcp_admins"]
#   id = "REPLACE_WITH_GCP_ADMINS_GROUP_ID"
# }
# import {
#   to = googleworkspace_group.this["infra"]
#   id = "REPLACE_WITH_INFRA_GROUP_ID"
# }
#
# Group settings import by the group email:
# import {
#   to = googleworkspace_group_settings.this["ganymede_users"]
#   id = "ganymede-users@patchworklabs.org"
# }
#
# Memberships that GAM already added import as "<group id>/<member email>".
# Add one block per member only if you list that member in group_members.
# Otherwise the first apply tries to add the member again and can fail with an "already exists" error.
