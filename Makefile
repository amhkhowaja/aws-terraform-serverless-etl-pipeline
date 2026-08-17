SHELL := /usr/bin/env bash

TF := terraform -chdir=terraform
PIP ?= .venv/bin/pip
PY ?= .venv/bin/python
JUPYTER ?= .venv/bin/jupyter
NOTEBOOK ?= notebooks/car_price_model.ipynb
SAMPLE ?= ml_sample_data_snapsoft.csv
PROFILE ?= car-sales
REGION ?= eu-central-1
FLOCI_ENDPOINT ?= http://localhost:4566
APPROVE ?=

FLOCI_ENV := AWS_ENDPOINT_URL=$(FLOCI_ENDPOINT) AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=$(REGION)
CLOUD_ENV := AWS_PROFILE=$(PROFILE)
TEST_ENV := AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=$(REGION) CURATED_ZONE_BUCKET=unused

.DEFAULT_GOAL := help

.PHONY: help venv build fmt validate init test \
        floci-up floci-down apply-floci upload-floci verify-floci logs-floci destroy-floci \
        apply-aws upload-aws verify-aws logs-aws destroy-aws verify-clean \
        notebook notebook-run notebook-run-aws demo-floci demo-aws clean

help:
	@echo "Setup"
	@echo "  make venv           create .venv and install requirements"
	@echo "  make build          build the lambda deployment package"
	@echo "  make test           run the transform against the sample csv, no aws needed"
	@echo ""
	@echo "Local target, floci"
	@echo "  make floci-up       start the floci emulator"
	@echo "  make apply-floci    deploy the stack to floci"
	@echo "  make upload-floci   upload the sample csv to the landing zone"
	@echo "  make verify-floci   show the curated object and its metadata"
	@echo "  make logs-floci     tail the lambda log"
	@echo "  make destroy-floci  tear down the floci stack"
	@echo "  make floci-down     stop the floci emulator"
	@echo "  make demo-floci     build, apply, upload and verify in one go"
	@echo ""
	@echo "Cloud target, real aws"
	@echo "  make apply-aws      deploy the stack to aws"
	@echo "  make upload-aws     upload the sample csv to the landing zone"
	@echo "  make verify-aws     show the curated object and its metadata"
	@echo "  make logs-aws       tail the lambda log"
	@echo "  make destroy-aws    tear down the aws stack"
	@echo "  make verify-clean   confirm nothing billable remains in aws"
	@echo "  make demo-aws       build, apply, upload and verify in one go"
	@echo ""
	@echo "Notebook"
	@echo "  make notebook       open the notebook in jupyter lab"
	@echo "  make notebook-run   execute the notebook headlessly against floci"
	@echo "  make notebook-run-aws execute the notebook headlessly against aws"
	@echo ""
	@echo "Terraform"
	@echo "  make init           terraform init"
	@echo "  make validate       terraform validate"
	@echo "  make fmt            terraform fmt"
	@echo ""
	@echo "  make clean          remove build artifacts and caches"
	@echo ""
	@echo "Override defaults, for example: make apply-aws PROFILE=myprofile REGION=eu-west-1"

venv:
	python3 -m venv .venv
	$(PIP) install --quiet --upgrade pip
	$(PIP) install --quiet -r requirements.txt
	@echo "environment ready"

build:
	./build.sh

test:
	@$(TEST_ENV) $(PY) -c "\
	import sys; sys.path.insert(0, 'lambda');\
	import pandas as pd, process_data as p;\
	df = pd.read_csv('$(SAMPLE)', usecols=lambda c: c not in p.drop_columns, dtype={'CarName':'string','saledate':'string'});\
	out, n = p.transform(df);\
	print('rows in  ', n);\
	print('rows out ', len(out));\
	print('columns  ', len(out.columns));\
	print('schema ok', list(out.columns) == p.output_columns);\
	print('pii gone ', not set(p.drop_columns) & set(out.columns));\
	print('nulls    ', int(out.isna().sum().sum()))"

init:
	$(TF) init

validate:
	$(TF) validate

fmt:
	$(TF) fmt -recursive

floci-up:
	floci start
	floci doctor

floci-down:
	floci stop

apply-floci: init
	$(TF) workspace select default
	$(TF) apply $(APPROVE) -var-file=env/floci.tfvars

upload-floci:
	$(TF) workspace select default
	$(FLOCI_ENV) aws s3 cp $(SAMPLE) \
	  s3://$$($(TF) output -raw landing_bucket)/$$($(TF) output -raw landing_prefix)
	@echo "uploaded, the curated object appears within about 30 seconds"

verify-floci:
	$(TF) workspace select default
	@bucket=$$($(TF) output -raw curated_bucket); \
	prefix=$$($(TF) output -raw curated_object_prefix); \
	$(FLOCI_ENV) aws s3 ls s3://$$bucket/$$prefix/ --recursive; \
	key=$$($(FLOCI_ENV) aws s3api list-objects-v2 --bucket $$bucket --prefix $$prefix/ \
	  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text); \
	$(FLOCI_ENV) aws s3api head-object --bucket $$bucket --key "$$key" --query Metadata

logs-floci:
	$(TF) workspace select default
	@group=$$($(TF) output -raw log_group_name); \
	stream=$$($(FLOCI_ENV) aws logs describe-log-streams --log-group-name $$group \
	  --query 'logStreams[-1].logStreamName' --output text); \
	$(FLOCI_ENV) aws logs get-log-events --log-group-name $$group --log-stream-name "$$stream" \
	  --query 'events[].message' --output text | tr '\t' '\n'

destroy-floci:
	$(TF) workspace select default
	$(TF) destroy $(APPROVE) -var-file=env/floci.tfvars

apply-aws: init
	$(TF) workspace select aws || $(TF) workspace new aws
	$(CLOUD_ENV) $(TF) apply $(APPROVE) -var-file=env/aws.tfvars

upload-aws:
	$(TF) workspace select aws
	$(CLOUD_ENV) aws s3 cp $(SAMPLE) \
	  s3://$$($(TF) output -raw landing_bucket)/$$($(TF) output -raw landing_prefix)
	@echo "uploaded, the curated object appears within about 10 seconds"

verify-aws:
	$(TF) workspace select aws
	@bucket=$$($(TF) output -raw curated_bucket); \
	prefix=$$($(TF) output -raw curated_object_prefix); \
	$(CLOUD_ENV) aws s3 ls s3://$$bucket/$$prefix/ --recursive; \
	key=$$($(CLOUD_ENV) aws s3api list-objects-v2 --bucket $$bucket --prefix $$prefix/ \
	  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text); \
	$(CLOUD_ENV) aws s3api head-object --bucket $$bucket --key "$$key" --query Metadata

logs-aws:
	$(TF) workspace select aws
	$(CLOUD_ENV) aws logs tail $$($(TF) output -raw log_group_name) --since 15m

destroy-aws:
	$(TF) workspace select aws
	$(CLOUD_ENV) $(TF) destroy $(APPROVE) -var-file=env/aws.tfvars

verify-clean:
	@echo "terraform state : $$($(TF) state list 2>/dev/null | wc -l | tr -d ' ') resources"
	@echo "s3 buckets      : $$($(CLOUD_ENV) aws s3 ls 2>/dev/null | grep -c car-sales)"
	@echo "sqs queues      : $$($(CLOUD_ENV) aws sqs list-queues --query 'QueueUrls' --output text 2>/dev/null | grep -c car-sales)"
	@echo "lambda funcs    : $$($(CLOUD_ENV) aws lambda list-functions --query 'Functions[].FunctionName' --output text 2>/dev/null | grep -c car-sales)"
	@echo "log groups      : $$($(CLOUD_ENV) aws logs describe-log-groups --query 'logGroups[].logGroupName' --output text 2>/dev/null | grep -c car-sales)"
	@echo "iam roles       : $$($(CLOUD_ENV) aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null | grep -c car-sales)"
	@echo "all zero means nothing billable remains"

notebook:
	$(FLOCI_ENV) $(JUPYTER) lab $(NOTEBOOK)

notebook-run:
	$(FLOCI_ENV) $(JUPYTER) nbconvert --to notebook --execute --inplace \
	  --ExecutePreprocessor.timeout=900 $(NOTEBOOK)

notebook-run-aws:
	$(TF) workspace select aws
	@bucket=$$($(TF) output -raw curated_bucket); \
	$(CLOUD_ENV) CURATED_ZONE_BUCKET=$$bucket $(JUPYTER) nbconvert --to notebook --execute \
	  --inplace --ExecutePreprocessor.timeout=900 $(NOTEBOOK)

demo-floci:
	@curl -s -o /dev/null --max-time 3 $(FLOCI_ENDPOINT) || floci start
	@$(MAKE) build
	@$(MAKE) apply-floci APPROVE=-auto-approve
	@$(MAKE) upload-floci
	@echo "waiting for the lambda to run"
	@sleep 35
	@$(MAKE) verify-floci
	@$(MAKE) logs-floci

demo-aws:
	@$(MAKE) build
	@$(MAKE) apply-aws APPROVE=-auto-approve
	@$(MAKE) upload-aws
	@echo "waiting for the lambda to run"
	@sleep 15
	@$(MAKE) verify-aws
	@$(MAKE) logs-aws

clean:
	rm -rf terraform/build
	rm -rf lambda/__pycache__
	find . -name "*.pyc" -delete
	@echo "build artifacts removed, terraform state left untouched"
