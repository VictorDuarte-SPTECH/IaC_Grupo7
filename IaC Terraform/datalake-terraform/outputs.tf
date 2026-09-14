output "bronze_bucket_name" {
  description = "Nome gerado para o bucket Bronze."
  value       = aws_s3_bucket.bronze.id
}

output "silver_bucket_name" {
  description = "Nome gerado para o bucket Silver."
  value       = aws_s3_bucket.silver.id
}

output "gold_bucket_name" {
  description = "Nome gerado para o bucket Gold."
  value       = aws_s3_bucket.gold.id
}

output "data_lake_bucket_arns" {
  description = "ARNs que poderao ser usados posteriormente pelas roles e jobs do AWS Glue."
  value = {
    bronze = aws_s3_bucket.bronze.arn
    silver = aws_s3_bucket.silver.arn
    gold   = aws_s3_bucket.gold.arn
  }
}
