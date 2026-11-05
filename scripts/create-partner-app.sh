#!/usr/bin/env bash
# Creates the "FundMate Underwriting Partner" connected app (OAuth client credentials, runs as the
# integration user) and grants it to the FundMate_Integration permission set.
# The client id and secret are generated into .env.local and never written to the repository.
#   scripts/create-partner-app.sh <org alias>
set -euo pipefail
ORG="${1:?Usage: scripts/create-partner-app.sh <org alias>}"
cd "$(dirname "$0")/.."
sf apex run -o "$ORG" -f scripts/apex/create-integration-user.apex >/dev/null
USERNAME="fundmate.integration.$(sf org display -o "$ORG" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["id"][:15].lower())')@example.com"
grep -q '^PARTNER_CLIENT_ID=' .env.local 2>/dev/null || printf "PARTNER_CLIENT_ID=FundMatePartner%s\nPARTNER_CLIENT_SECRET=%s\n" "$(openssl rand -hex 8)" "$(openssl rand -hex 32)" >> .env.local
CID=$(grep '^PARTNER_CLIENT_ID=' .env.local | cut -d= -f2)
CSEC=$(grep '^PARTNER_CLIENT_SECRET=' .env.local | cut -d= -f2)
EMAIL=$(sf data query -o "$ORG" -q "SELECT Email FROM User WHERE Username = '$USERNAME'" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["records"][0]["Email"])')
TMP=$(mktemp -d); mkdir -p "$TMP/connectedApps"
sed -e "s#__EMAIL__#$EMAIL#" -e "s#__CLIENT_ID__#$CID#" -e "s#__CLIENT_SECRET__#$CSEC#" -e "s#__USERNAME__#$USERNAME#" \
  org-config/FundMate_Underwriting_Partner.connectedApp-meta.xml.template > "$TMP/connectedApps/FundMate_Underwriting_Partner.connectedApp-meta.xml"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata"><types><members>FundMate_Underwriting_Partner</members><name>ConnectedApp</name></types><version>66.0</version></Package>\n' > "$TMP/package.xml"
sf project deploy start -o "$ORG" --metadata-dir "$TMP" --wait 10 >/dev/null
rm -rf "$TMP"
echo "Id app = [SELECT Id FROM ConnectedApplication WHERE Name = 'FundMate Underwriting Partner' LIMIT 1].Id; Id ps = [SELECT Id FROM PermissionSet WHERE Name = 'FundMate_Integration' LIMIT 1].Id; if ([SELECT COUNT() FROM SetupEntityAccess WHERE ParentId = :ps AND SetupEntityId = :app] == 0) insert new SetupEntityAccess(ParentId = ps, SetupEntityId = app);" | sf apex run -o "$ORG" >/dev/null
echo "Partner app ready. It runs as $USERNAME; credentials are in .env.local (PARTNER_CLIENT_ID / PARTNER_CLIENT_SECRET)."
