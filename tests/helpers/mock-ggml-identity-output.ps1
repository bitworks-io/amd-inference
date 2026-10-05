param([ValidateSet('single','duplicate','overflow','timeout')][string]$Mode = 'single')
$record = '{"schemaVersion":1,"applicable":true,"qualified":false,"identityScope":"independent-process-advisory","sourceEngineArchiveSha256":"31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5","devices":[]}'
if ($Mode -eq 'timeout') { Start-Sleep -Seconds 5; return }
if ($Mode -eq 'overflow') { 1..40 | ForEach-Object { Write-Output ('x' * 8192) } }
Write-Output ('FASTLLM_GGML_IDENTITY_JSON:' + $record)
if ($Mode -eq 'duplicate') {
    Start-Sleep -Milliseconds 200
    Write-Output ('FASTLLM_GGML_IDENTITY_JSON:' + $record)
}
