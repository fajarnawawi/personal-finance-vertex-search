-- Receipt data: merchant info, line items, OCR confidence, user confirmation state
-- Partitioned by upload date; clustered by category + date for spend query patterns
CREATE TABLE IF NOT EXISTS `${PROJECT_ID}.finance_brain.receipts` (
  receipt_id STRING NOT NULL,
  uploaded_at TIMESTAMP NOT NULL,
  merchant_name STRING,
  merchant_category STRING,
  transaction_date DATE,
  currency STRING,
  subtotal NUMERIC,
  tax NUMERIC,
  service_charge NUMERIC,
  total NUMERIC,
  payment_method STRING,
  line_items ARRAY<STRUCT<
    description STRING,
    quantity NUMERIC,
    unit_price NUMERIC,
    line_total NUMERIC
  >>,
  raw_ocr_text STRING,
  image_gcs_uri STRING,
  ocr_confidence FLOAT64,
  extraction_model_version STRING,
  user_confirmed BOOL,
  user_edits STRING
)
PARTITION BY DATE(uploaded_at)
CLUSTER BY merchant_category, transaction_date;
