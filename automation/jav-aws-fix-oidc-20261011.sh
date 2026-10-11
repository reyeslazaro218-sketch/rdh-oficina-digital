#!/usr/bin/env bash
# Repair only the trust subject for the dedicated JAV GitHub OIDC role.
set -euo pipefail
export AWS_PAGER=""
EXPECTED_ACCOUNT="647870082689"
ROLE="JAV-GITHUB-AWS-AGENT"
OLD_SUB="repo:reyeslazaro218-sketch/JAV:ref:refs/heads/main"
NEW_SUB="repo:reyeslazaro218-sketch@252656826/JAV@1406688660:ref:refs/heads/main"
account="$(aws sts get-caller-identity --query Account --output text)"
if [ "$account" != "$EXPECTED_ACCOUNT" ]; then
  echo "DETENIDO: Cuenta AWS distinta" >&2
  exit 1
fi
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
aws iam get-role --role-name "$ROLE" --query Role.AssumeRolePolicyDocument --output json > "$tmpdir/actual.json"
python3 - "$tmpdir/actual.json" "$tmpdir/updated.json" "$EXPECTED_ACCOUNT" "$OLD_SUB" "$NEW_SUB" <<'PY'
import json,sys
input_path, output_path, account, old_sub, new_sub = sys.argv[1:]
data=json.load(open(input_path))
stmts=data.get("Statement")
if not isinstance(stmts,list) or len(stmts)!=1:
    raise SystemExit("DETENIDO: el rol tiene una politica de confianza inesperada")
stmt=stmts[0]
expected={
    "Effect":"Allow",
    "Principal":{"Federated":f"arn:aws:iam::{account}:oidc-provider/token.actions.githubusercontent.com"},
    "Action":"sts:AssumeRoleWithWebIdentity",
}
for k,v in expected.items():
    if stmt.get(k)!=v:
        raise SystemExit(f"DETENIDO: politica inesperada en {k}")
condition=stmt.get("Condition",{})
if list(condition)!=["StringEquals"]:
    raise SystemExit("DETENIDO: condiciones de confianza inesperadas")
values=condition["StringEquals"]
aud=values.get("token.actions.githubusercontent.com:aud")
sub=values.get("token.actions.githubusercontent.com:sub")
if set(values)!={"token.actions.githubusercontent.com:aud","token.actions.githubusercontent.com:sub"} or aud!="sts.amazonaws.com" or sub not in (old_sub,new_sub):
    raise SystemExit("DETENIDO: valores aud/sub inesperados")
data["Statement"][0]["Condition"]["StringEquals"]["token.actions.githubusercontent.com:sub"]=new_sub
with open(output_path,"w") as f: json.dump(data,f)
PY
aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "file://$tmpdir/updated.json"
sleep 3
aws iam get-role --role-name "$ROLE" --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:sub"' --output text | grep -Fxq "$NEW_SUB"
printf 'JAV OIDC TRUST CORREGIDO: %s\n' "$ROLE"
printf 'Cuenta: %s\nSin cambios EC2, EBS, red o facturacion.\n' "$account"
