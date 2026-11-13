# The 9 workflows: n8n id (the same on laptop and server, import keeps it), name, source file, and the settings the .sdk.ts files cannot
# carry. One list for check-error-workflows.ps1, check-sdk-drift.ps1 and import-workflows.ps1, so the import cannot set an errorWorkflow
# that the check does not expect. Dot-source it: . "$PSScriptRoot\lib\workflows.ps1"
# ErrorHandler = $true: errorWorkflow must point at the Error Handler. The Error Handler and Send Alert have none (a failing alert must
# never trigger another alert); the two invoice sub-workflows have none either (they return `problem`, the Processor reports it).
# Settings: everything else the live workflow has besides errorWorkflow (laptop export, 2026-11-12; availableInMCP left out: the server
# has no MCP, and check-sdk-drift.ps1 does not compare settings).
# ServerSettings: only on the server (import-workflows.ps1 sets them, check-error-workflows.ps1 -Target Server checks them).
# saveDataSuccessExecution = none: the Monitor (owner decision 2026-11-12: 288 runs a day less, no ping URL in execution data), and since
# M7c every workflow that sees visitor data (name, generated email, token): Intake, Processor, Render Invoice, Send Telegram and the two
# demo workflows. Failed runs are still saved, for at most EXECUTIONS_DATA_MAX_AGE (48 h). Not on the laptop: its stack is retired (M7b-7).
# Demo Checkout and Demo Result exist only on the server (M7c).

$ErrorHandlerWorkflowId = 'c2NT8k3JGpuS3r6I'

function Get-Workflows {
    $noSuccess = @{ saveDataSuccessExecution = 'none' }
    return @(
        [pscustomobject]@{ Id = '3j0pWVoxvDY2sdO5'; Name = 'Stripe Intake';         File = 'stripe-intake.sdk.ts';         ErrorHandler = $true;  Settings = @{ executionOrder = 'v1' }; ServerSettings = $noSuccess }
        [pscustomobject]@{ Id = 'ylR2t9B0ZAH1cLfq'; Name = 'Stripe Processor';      File = 'stripe-processor.sdk.ts';      ErrorHandler = $true;  Settings = @{ executionOrder = 'v1'; binaryMode = 'separate' }; ServerSettings = $noSuccess }
        [pscustomobject]@{ Id = 'yeSlEcPp87vCJT7D'; Name = 'Stripe Monitor';        File = 'stripe-monitor.sdk.ts';        ErrorHandler = $true;  Settings = @{ executionOrder = 'v1' }; ServerSettings = $noSuccess }
        [pscustomobject]@{ Id = 'c2NT8k3JGpuS3r6I'; Name = 'Stripe Error Handler';  File = 'stripe-error-handler.sdk.ts';  ErrorHandler = $false; Settings = @{ executionOrder = 'v1' } }
        [pscustomobject]@{ Id = 'WO2ebvkZGK5NxzVo'; Name = 'Stripe Send Alert';     File = 'stripe-send-alert.sdk.ts';     ErrorHandler = $false; Settings = @{ executionOrder = 'v1' } }
        [pscustomobject]@{ Id = '3dvdSRSD6ObBVsxy'; Name = 'Stripe Render Invoice'; File = 'stripe-render-invoice.sdk.ts'; ErrorHandler = $false; Settings = @{ executionOrder = 'v1' }; ServerSettings = $noSuccess }
        [pscustomobject]@{ Id = 'Yel7C2ufq8wR5s3W'; Name = 'Stripe Send Telegram';  File = 'stripe-send-telegram.sdk.ts';  ErrorHandler = $false; Settings = @{ executionOrder = 'v1' }; ServerSettings = $noSuccess }
        [pscustomobject]@{ Id = 'dmCk7Qp2Lx9RtV4a'; Name = 'Demo Checkout';         File = 'demo-checkout.sdk.ts';         ErrorHandler = $true;  Settings = @{ executionOrder = 'v1' }; ServerSettings = $noSuccess }
        [pscustomobject]@{ Id = 'dmRs3Hn8Wz5KyB6e'; Name = 'Demo Result';           File = 'demo-result.sdk.ts';           ErrorHandler = $true;  Settings = @{ executionOrder = 'v1'; binaryMode = 'separate' }; ServerSettings = $noSuccess }
    )
}
