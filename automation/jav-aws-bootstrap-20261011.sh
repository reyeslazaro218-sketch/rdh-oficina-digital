#!/usr/bin/env bash
# JAV bootstrap: AWS CloudShell only. No secrets, payments, or Binance commands.
set -euo pipefail
umask 077
export AWS_PAGER=""
REGION=us-east-2
EXPECTED_ACCOUNT="${1:-}"
VPC=vpc-090ce181574ee70f3
SUBNET=subnet-0cafd1d697f8dea48
SG_NAME=JAV-EC2-NO-INBOUND
NAME=JAV-AWS-RECOVERY-01
EC2_PROFILE=JAV-EC2-SSM-ROLE
GH_ROLE=JAV-GITHUB-AWS-AGENT
GH_REPO=reyeslazaro218-sketch/JAV
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail(){ printf 'DETENIDO: %s\n' "$*" >&2; exit 1; }
check(){ printf 'JAV: %s\n' "$*"; }
[[ "$EXPECTED_ACCOUNT" =~ ^[0-9]{12}$ ]] || fail 'indica el ID de cuenta como parametro'
command -v aws >/dev/null || fail 'AWS CLI no disponible'
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || fail 'cuenta AWS diferente'
PLAN="$(aws freetier get-account-plan-state --region us-east-1 --query accountPlanType --output text)"
STATE="$(aws freetier get-account-plan-state --region us-east-1 --query accountPlanStatus --output text)"
CREDIT="$(aws freetier get-account-plan-state --region us-east-1 --query accountPlanRemainingCredits.amount --output text)"
[[ "$PLAN" == FREE && "$STATE" == ACTIVE ]] || fail 'Free Plan no esta activo'
python3 - "$CREDIT" <<'PY' || fail 'creditos inferiores a 25 USD'
import sys
try: assert float(sys.argv[1]) >= 25
except (ValueError,AssertionError): raise SystemExit(1)
PY
[[ "$(aws ec2 describe-instance-types --region "$REGION" --instance-types t3.micro --query 'InstanceTypes[0].FreeTierEligible' --output text)" == True ]] || fail 't3.micro no elegible'
[[ "$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$SUBNET" --query 'Subnets[0].VpcId' --output text)" == "$VPC" ]] || fail 'subred incorrecta'
[[ "$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC" --query 'Vpcs[0].IsDefault' --output text)" == True ]] || fail 'VPC incorrecta'
[[ "$(aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE" --query 'InstanceProfile.Roles[0].RoleName' --output text)" == "$EC2_PROFILE" ]] || fail 'perfil SSM incorrecto'
aws iam list-attached-role-policies --role-name "$EC2_PROFILE" --query 'AttachedPolicies[].PolicyName' --output text | grep -q AmazonSSMManagedInstanceCore || fail 'SSM no autorizado'
check 'Cuenta FREE, creditos, subred y perfil SSM verificados.'
# Federate only GitHub repo JAV/main; no permanent access keys.
OIDC="arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC" >/dev/null 2>&1; then
 aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com >/dev/null
fi
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC" --query ClientIDList --output text | grep -qw sts.amazonaws.com || fail 'OIDC no autoriza STS'
python3 - "$OIDC" "$GH_REPO" "$WORK/trust.json" <<'PY'
import json,sys
arn,repo,dest=sys.argv[1:]
doc={'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Federated':arn},'Action':'sts:AssumeRoleWithWebIdentity','Condition':{'StringEquals':{'token.actions.githubusercontent.com:aud':'sts.amazonaws.com','token.actions.githubusercontent.com:sub':f'repo:reyeslazaro218-sketch@252656826/JAV@1406688660:ref:refs/heads/main'}}}]}
with open(dest,'w') as f: json.dump(doc,f)
PY
if aws iam get-role --role-name "$GH_ROLE" >/dev/null 2>&1; then
 aws iam get-role --role-name "$GH_ROLE" --query Role.AssumeRolePolicyDocument --output json > "$WORK/existing-trust.json"
 python3 - "$WORK/trust.json" "$WORK/existing-trust.json" <<'PY' || fail 'Rol existente no tiene confianza esperada'
import json,sys
with open(sys.argv[1]) as f: expected=json.load(f)
with open(sys.argv[2]) as f: actual=json.load(f)
assert actual.get('Statement')==expected['Statement']
PY
else
 aws iam create-role --role-name "$GH_ROLE" --assume-role-policy-document "file://$WORK/trust.json" --description 'Only JAV repo main via GitHub OIDC; no static keys' >/dev/null
fi
check 'GitHub OIDC preparado sin claves permanentes.'
SG="$(aws ec2 describe-security-groups --region "$REGION" --filters Name=vpc-id,Values="$VPC" Name=group-name,Values="$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$SG" == None || -z "$SG" ]]; then
 SG="$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC" --group-name "$SG_NAME" --description 'JAV SSM node, zero inbound' --query GroupId --output text)"
 aws ec2 create-tags --region "$REGION" --resources "$SG" --tags Key=Project,Value=JAV >/dev/null
fi
[[ "$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG" --query 'length(SecurityGroups[0].IpPermissions)' --output text)" == 0 ]] || fail 'grupo de seguridad tiene entradas; abortado'
INSTANCE="$(aws ec2 describe-instances --region "$REGION" --filters Name=tag:Name,Values="$NAME" Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
if [[ -z "$INSTANCE" ]]; then
 AMI="$(aws ssm get-parameter --region "$REGION" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)"
 OWNER="$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" --query 'Images[0].OwnerId' --output text)"
 [[ "$OWNER" == 137112412989 ]] || fail 'imagen del sistema no es oficial de Amazon'
 ROOT="$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" --query 'Images[0].RootDeviceName' --output text)"
 [[ "$ROOT" == /dev/* ]] || fail 'dispositivo raiz desconocido'
 VOL="$(printf '[{"DeviceName":"%s","Ebs":{"VolumeSize":16,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' "$ROOT")"
 NET="$(printf '[{"DeviceIndex":0,"SubnetId":"%s","Groups":["%s"],"AssociatePublicIpAddress":true,"DeleteOnTermination":true}]' "$SUBNET" "$SG")"
 check 'Creando una t3.micro; usa creditos AWS, incluida IPv4 publica.'
 INSTANCE="$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" --instance-type t3.micro --iam-instance-profile Name="$EC2_PROFILE" --network-interfaces "$NET" --block-device-mappings "$VOL" --credit-specification CpuCredits=standard --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1 --client-token jav-aws-recovery-initial-20261011 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=JAV-AWS-RECOVERY-01},{Key=Project,Value=JAV},{Key=Role,Value=non-financial-pilot}]' --query 'Instances[0].InstanceId' --output text)"
fi
[[ "$INSTANCE" == i-* ]] || fail 'no hay ID EC2 confirmado'
python3 - "$ACCOUNT" "$REGION" "$INSTANCE" "$WORK/policy.json" <<'PY'
import json,sys
account,region,instance,dest=sys.argv[1:]
doc={'Version':'2012-10-17','Statement':[
 {'Sid':'DescribeJav','Effect':'Allow','Action':['ec2:DescribeInstances','ec2:DescribeInstanceStatus','ec2:DescribeSecurityGroups','ssm:DescribeInstanceInformation','ssm:GetCommandInvocation','ssm:ListCommandInvocations'],'Resource':'*'},
 {'Sid':'OnlyNewJavNode','Effect':'Allow','Action':'ssm:SendCommand','Resource':[f'arn:aws:ec2:{region}:{account}:instance/{instance}',f'arn:aws:ssm:{region}::document/AWS-RunShellScript']} ]}
with open(dest,'w') as f: json.dump(doc,f)
PY
aws iam put-role-policy --role-name "$GH_ROLE" --policy-name JAV-ONE-NODE-SSM-ONLY --policy-document "file://$WORK/policy.json" >/dev/null
printf '\nJAV CREADO/O EXISTENTE: %s\nREGION: %s\nGITHUB_OIDC_ROLE: %s\nSIN PUERTOS ENTRANTES\n' "$INSTANCE" "$REGION" "$GH_ROLE"
printf 'No se ha desplegado software ni ejecutado operaciones financieras.\n'
