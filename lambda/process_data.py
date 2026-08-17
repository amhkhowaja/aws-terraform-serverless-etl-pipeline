import pandas as pd
import boto3
from datetime import datetime, timezone
import logging
import urllib.parse
import json

import io
import os

# env vars
curated_zone_bucket=os.environ.get("CURATED_ZONE_BUCKET")
curated_object_prefix = os.environ.get("CURATED_OBJECT_PREFIX", "curated_object")
landing_zone_bucket =os.environ.get("LANDING_ZONE_BUCKET")
aws_endpoint_url = os.environ.get("AWS_ENDPOINT_URL") or None

# config parameters for data processing
drop_columns = [
    "car_ID",
    "ownername",
    "owneremail",
    "dealershipaddress",
    "iban"
]

output_columns = [
    "brand", "CarName", "saledate", "fueltype", "aspiration", "doornumber",
    "carbody", "drivewheel", "enginelocation", "wheelbase", "color", "carlength",
    "carwidth", "carheight", "curbweight", "cylindernumber", "enginesize", "compressionratio", 
    "horsepower", "peakrpm", "citympg", "highwaympg", "Price"

]

required_columns = [
    "CarName", "fueltype", "aspiration", "doornumber","carbody", "drivewheel",
    "enginelocation", "wheelbase", "carlength", "carwidth","carheight",
    "curbweight", "cylindernumber", "enginesize", "compressionratio","horsepower",
    "peakrpm", "citympg", "highwaympg", "Price",
]

# based on exploratory data analysis i asked ai to do .
brand_corrections = {
      "maxda": "mazda",
      "porcshce": "porsche",
      "toyouta": "toyota",
      "vokswagen": "volkswagen",
      "vw": "volkswagen",
}

# logging config, i defaulted to info level
LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


# creating s3 client.
s3_client = boto3.client("s3", endpoint_url=aws_endpoint_url)


class InvalidFile(Exception):
    pass


def load_csv_from_landingzone(bucket, key):
    body = s3_client.get_object(Bucket=bucket, Key=key)["Body"].read()
    headings = pd.read_csv(io.BytesIO(body), nrows=0).columns

    missing = [column for column in required_columns if column not in headings]
    if missing:
        raise InvalidFile(f"missing required columns: {missing}")

    return pd.read_csv(
        io.BytesIO(body),
        usecols=lambda c: c not in drop_columns,
        dtype={"CarName":"string", "saledate":"string"},
        encoding="utf-8-sig",
        skip_blank_lines=True
    )   


def transform(df):
    rows_in = len(df)

    car_name = df["CarName"].str.strip()

    # only filled car names would be accepted and missing carnames would be droped
    car_name_keep = car_name.notna() & car_name.ne("")
    df = df.loc[car_name_keep].copy()
    df["CarName"] = car_name.loc[car_name_keep]

    # correcting mispelled car brand names
    df["brand"] = (
        df["CarName"]
        .str.lower()
        .str.split()
        .str[0]
        .replace(brand_corrections)
    )

    df = df.reindex(columns=output_columns)
    return df, rows_in


def build_output_key(source_key):
    stem = os.path.basename(source_key).removesuffix(".csv")
    ingest_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return f"{curated_object_prefix}/ingest_date={ingest_date}/{stem}.csv"


def process_object(bucket, key):
    df, rows_in = transform(load_csv_from_landingzone(bucket, key))

    if df.empty:
        LOG.warning(json.dumps({
            "event": "no_rows_written",
            "source_key": key,
            "rows_in": rows_in,
            "rows_out": 0,
        }))
        return None

    output_key = build_output_key(key)
    s3_client.put_object(
        Bucket=curated_zone_bucket,
        Key=output_key,
        Body=df.to_csv(index=False).encode("utf-8"),
        ContentType="text/csv",
        Metadata={
            "rows-in": str(rows_in),
            "rows-out": str(len(df)),
            "rows-dropped": str(rows_in - len(df)),
            "source-key": key,
        },
    )

    LOG.info(json.dumps({
        "event": "curated_written",
        "source_key": key,
        "curated_key": output_key,
        "rows_in": rows_in,
        "rows_out": len(df),
        "rows_dropped": rows_in - len(df),
        "columns_out": len(df.columns),
        "null_cells_retained": int(df.isna().sum().sum()),
    }))
    return output_key

def extract_s3_records(event):
    records = []
    for message in event.get("Records", []):
        if "s3" in message:
            records.append(message["s3"])
            continue
        body = message.get("body")
        if not body:
            continue
        try:
            inner = json.loads(body)
        except json.JSONDecodeError:
            LOG.warning(json.dumps({"event": "unparsable_sqs_body"}))
            continue
        if inner.get("Event") == "s3:TestEvent":
            continue
        records.extend(r["s3"] for r in inner.get("Records", []) if "s3" in r)
    return records

def handler(events, context):
    written = []
    for record in extract_s3_records(events):
        bucket = record["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["object"]["key"])
        try:
            output_key = process_object(bucket, key)
        except InvalidFile as e:
            LOG.error(
                json.dumps(
                    {
                        "event": "file_rejected",
                        "source_key": key,
                        "reason": str(e)
                    }
                )
            )
            raise
        if output_key:
            written.append(output_key)
    return {"curated_objects": written}





