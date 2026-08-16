output "state_bucket_name" {
  description = "Paste this into foundation/backend.tf (and later chaosforge/, rpe/) as the `bucket` value"
  value       = aws_s3_bucket.tfstate.bucket
}
