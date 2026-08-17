# Serverless ETL Pipeline for Car Resale Price Prediction

An event driven ETL pipeline on AWS, provisioned entirely with Terraform. A CSV of previous car
sales lands in an S3 landing zone bucket, an S3 event notification puts a message on SQS, a Lambda function
preprocesses the file, and the cleaned result is written to an S3 curated zone bucket. A Jupyter notebook then trains and evaluates a price model from the curated zone bucket.

The same Terraform deploys to real AWS or to Floci (Local AWS Emulator)



## Prerequisites

Tools Used:

- `Terraform` : 1.15
- `AWS CLI` : 2.36.24
- `Python` : 3.12 or newer
- `Docker` : Only for Floci.io
- `floci cli` : only for local target



Python dependencies: Install it from this command.

```bash
make venv
```

That creates `.venv` and installs `requirements.txt`. The equivalent by hand:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Quick start

Everything is wrapped in a Makefile. Run `make help` to list every target.

One command takes you from nothing to a verified pipeline and cleaned output:

```bash
make demo-floci
```

It starts the emulator if needed, builds the Lambda package, applies the Terraform, uploads the
sample CSV, waits for the event to be processed, then prints the curated object, its metadata and the
Lambda log. The same thing against real AWS:

```bash
make demo-aws
```

Tear down with `make destroy-floci` or `make destroy-aws`.

The sections below explain each step, and give the raw commands in case you want to run them
individually.

## Build the Lambda package

The Lambda needs pandas, so the deployment package has to be built before you deploy it. Run this
from the repository root:

```bash
make build
```

Run it again whenever you change `lambda/process_data.py`. The deploy targets do not rebuild for you.

You can check the transform without any AWS access at all:

```bash
make test
```

That runs the preprocessing against the sample CSV and prints the row counts, column count, schema
check and null count.

`make build` wraps `./build.sh`, which you can also call directly.

### macOS and Linux

> This project was built and tested on macOS with an Apple Silicon arm64 chip.

The script works on both, and it does not matter whether your machine is Intel or ARM. pip is told
which platform to build for, so you get the right wheels either way.

It looks for pip in `.venv/bin/pip`. If your virtual environment lives somewhere else, point it at
the right one:

```bash
PIP=pip ./build.sh
```

On Windows, run it under WSL or Git Bash.


## Deploy to real AWS

Configure credentials once.

```bash
aws configure --profile car-sales
```

The deploying principal needs S3, SQS, Lambda, CloudWatch Logs and IAM permissions. IAM is required
because Terraform creates the Lambda execution role.

Then:

```bash
make build
make apply-aws
make upload-aws
make verify-aws
make logs-aws
```

Apply takes roughly two minutes, most of it waiting on SQS. `make upload-aws` puts the sample CSV
under the `incoming/` prefix, which is what the notification filters on, so you do not have to
remember it.

A curated object appears within about 10 seconds. `make verify-aws` prints it with its metadata, and
`make logs-aws` shows the single structured line:

```json
{"event": "curated_written", "rows_in": 245, "rows_out": 235,
 "rows_dropped": 10, "columns_out": 23, "null_cells_retained": 21}
```

If your profile or region differs from the defaults:

```bash
make apply-aws PROFILE=myprofile REGION=eu-west-1
```

## Deploy Locally to floci (emulation to real AWS)

> scroll up for real AWS Deploy:
> I tested first on floci for cost cutting and then on real aws.

floci needs Docker, and it starts a real Lambda container, so the Docker socket must be reachable.

```bash
make floci-up
make build
make apply-floci
make upload-floci
make verify-floci
make logs-floci
```

No credentials to configure and no environment variables to export. The Makefile passes the local
endpoint and placeholder keys to every command.

Behaviour is identical to AWS, only slower: the curated object appears in about 25 seconds rather
than 8, because of floci's event source mapping poll interval.

Stop the emulator with `make floci-down`.

## How one codebase targets both Real AWS and Floci

`var.aws_endpoint_url` is the only switch. Empty string "" means real AWS, and
`"http://localhost:4566"` means floci.


## Run the notebook

With the pipeline deployed and a curated object present:

```bash
make notebook
```

That opens Jupyter Lab pointed at the floci curated zone. To execute it headlessly instead:

```bash
make notebook-run
make notebook-run-aws
```

The notebook finds the curated bucket by itself, and the same boto3 code reads from floci or real AWS
depending on which target you use.


## Teardown

```bash
make destroy-aws
make destroy-floci
```

Both buckets use `force_destroy = true`, so Terraform empties them first rather than failing on a non empty bucket(Just for demo for cost optimization).

Confirm nothing survives:

```bash
make verify-clean
```

The CloudWatch log group is declared in Terraform on purpose. Left implicit, Lambda would create it on first invocation, it would sit outside Terraform state, and it would survive teardown forever with no expiry.

One thing Terraform cannot clean up, because it was created outside Terraform, is the access key you
made in the console:

```bash
aws iam delete-access-key --user-name <deploy-user> --access-key-id <key-id>
```

IAM itself is free , just for secure infrastructure, good practice to delete access key.

## What the preprocessing does

The brief asks for three transformations. Each maps to a specific rule.


##### -  Delete attributes that cannot be used for training` :
- drops `car_ID`, `ownername`, `owneremail`, `dealershipaddress`, `iban`
##### - Delete rows missing significant attributes : 
- drops rows where `CarName`, the type of the car, is missing or blank
##### - Do not delete rows with imputable gaps :
- leaves 21 null cells intact for the notebook to impute 



Curated schema, 23 columns:

```
brand, CarName, saledate, fueltype, aspiration, doornumber, carbody, drivewheel,
enginelocation, wheelbase, color, carlength, carwidth, carheight, curbweight,
cylindernumber, enginesize, compressionratio, horsepower, peakrpm, citympg,
highwaympg, Price
```

## The model

`HistGradientBoostingRegressor` with `loss="quantile"` and `quantile=0.25`, inside an sklearn

The underestimation requirement is met by the **training objective**, not by discounting a neutral
prediction. Quantile loss below the median shifts predictions down by a tunable, measurable amount,
so the business can be told what fraction of quotes are expected to exceed the eventual sale price,
and that number is a fitted property of the model.

Measured out of fold on 235 rows and 18 features, 5 fold shuffled KFold, both models on identical
folds:

| | MAE | RMSE | R2 | Overprediction rate | Mean signed error |
|---|---|---|---|---|---|
| neutral, squared error | 1224 | 2107 | 0.926 | 49.8% | -42 |
| tilted, quantile alpha 0.25 | 1408 | 2296 | 0.912 | **39.6%** | **-583** |

Stability across 5 seeds, which matters at this sample size:

```
neutral  MAE 1266.2 +/- 30.3   overprediction 0.4970 +/- 0.0106
tilted   MAE 1373.2 +/- 27.8   overprediction 0.3932 +/- 0.0111
```

The 10 point gap in overprediction rate against a 1 point standard deviation confirms the effect is
real and not a favourable split.

`alpha` is the dial. The notebook sweeps it so the tradeoff is explicit rather than asserted. Below
about 0.15 accuracy collapses, with R2 falling from 0.91 to 0.87 and lower, so the model stops being
slightly conservative and simply becomes wrong.

Four columns are dropped as features in the notebook rather than in the Lambda, because they can
legally be used but were measured not to help: `color` costs 43.8 MAE, `doornumber` is inside noise,
and `saledate` costs 50 to 95 MAE with no temporal drift to justify it. They remain in the curated
zone so an analyst can still query them.
