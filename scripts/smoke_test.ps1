#Requires -Version 7.0
param(
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
$backend = 'http://localhost:8000'
$aiEngine = 'http://localhost:8001'
$demoEmail = 'user1@sharegrid.vn'
$state = @{}
$results = [System.Collections.Generic.List[string]]::new()

function Invoke-Api {
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        $Body
    )

    $options = @{
        Uri                = $Uri
        Method             = $Method
        Headers            = $Headers
        TimeoutSec         = 30
        NoProxy            = $true
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) {
        $options.ContentType = 'application/json; charset=utf-8'
        $options.Body = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 40 -Compress }
    }
    Invoke-WebRequest @options
}

function Assert-Status {
    param($Response, [int]$Expected)

    if ($Response.StatusCode -eq $Expected) {
        return
    }
    $message = "HTTP $($Response.StatusCode), kỳ vọng $Expected"
    if ($Response.Content -and $Response.Headers['Content-Type'] -like 'application/json*') {
        $detail = ($Response.Content | ConvertFrom-Json).detail
        if ($detail -is [string]) {
            $message += " ($detail)"
        }
    }
    throw $message
}

function Assert-Login {
    if (-not $state.authHeaders) {
        throw 'Cần đăng nhập thành công ở bước 2'
    }
}

function Invoke-Check {
    param([int]$Number, [string]$Name, [scriptblock]$Check)

    try {
        $message = & $Check
        $results.Add('PASS')
        Write-Host ('[{0:00}] PASS {1} | {2}' -f $Number, $Name, $message)
    } catch {
        $results.Add('FAIL')
        Write-Host ('[{0:00}] FAIL {1} | {2}' -f $Number, $Name, $_.Exception.Message)
    }
}

Invoke-Check 1 'Health backend và AI Engine' {
    $checks = [ordered]@{ backend = "$backend/"; 'AI Engine' = "$aiEngine/health" }
    $outcomes = foreach ($name in $checks.Keys) {
        try {
            $response = Invoke-Api $checks[$name]
            [pscustomobject]@{
                Ok = $response.StatusCode -eq 200
                Message = "$name HTTP $($response.StatusCode)"
            }
        } catch {
            [pscustomobject]@{ Ok = $false; Message = "$name ($($_.Exception.Message))" }
        }
    }
    $message = $outcomes.Message -join ', '
    if ($outcomes.Ok -contains $false) {
        throw $message
    }
    $message
}

Invoke-Check 2 "Đăng nhập $demoEmail" {
    if ($NoPrompt) {
        throw 'Chưa có mật khẩu demo trong lần chạy tự động (-NoPrompt)'
    }
    $password = Read-Host "Mật khẩu demo cho $demoEmail" -AsSecureString
    if ($null -eq $password -or $password.Length -eq 0) {
        throw 'Chưa nhập mật khẩu demo'
    }
    $credential = [pscredential]::new($demoEmail, $password)
    try {
        $response = Invoke-Api "$backend/api/v1/auth/login" -Method POST -Body @{
            email = $demoEmail
            password = $credential.GetNetworkCredential().Password
        }
    } finally {
        $password.Dispose()
    }
    Assert-Status $response 200
    $login = $response.Content | ConvertFrom-Json
    if (-not $login.access_token -or -not $login.user.user_id) {
        throw 'HTTP 200 nhưng thiếu access_token hoặc user.user_id'
    }
    $state.authHeaders = @{ Authorization = "Bearer $($login.access_token)" }
    $state.userId = $login.user.user_id
    'HTTP 200, đã lấy token'
}

Invoke-Check 3 'Danh sách mẫu xe' {
    $response = Invoke-Api "$backend/api/v1/vehicle-models"
    Assert-Status $response 200
    $models = $response.Content | ConvertFrom-Json
    $count = @($models.data | Where-Object { $null -ne $_ }).Count
    if ($models.count -ne 19 -or $count -ne 19) {
        throw "HTTP 200, nhận $count mẫu (count=$($models.count)), kỳ vọng 19"
    }
    'HTTP 200, 19 mẫu'
}

Invoke-Check 4 'Danh sách trạm ACTIVE' {
    $response = Invoke-Api "$backend/api/v1/stations?status=ACTIVE"
    Assert-Status $response 200
    $stations = $response.Content | ConvertFrom-Json
    $state.stations = @($stations.data | Where-Object { $_.status -ceq 'ACTIVE' })
    $count = $state.stations.Count
    if ($stations.count -ne 15 -or $count -ne 15 -or @($stations.data).Count -ne 15) {
        throw "HTTP 200, nhận $count trạm ACTIVE (count=$($stations.count)), kỳ vọng 15"
    }
    'HTTP 200, 15 trạm ACTIVE'
}

Invoke-Check 5 'Đặt lịch trong 24 giờ' {
    Assert-Login
    $response = Invoke-Api "$backend/api/v1/auth/me" -Headers $state.authHeaders
    Assert-Status $response 200
    $account = $response.Content | ConvertFrom-Json
    $vehicle = $account.vehicles | Sort-Object -Property is_default -Descending | Select-Object -First 1
    if (-not $vehicle) {
        throw 'Tài khoản demo chưa có xe'
    }

    $station = foreach ($candidate in $state.stations) {
        $response = Invoke-Api "$backend/api/v1/stations/$($candidate.station_id)"
        Assert-Status $response 200
        $ports = ($response.Content | ConvertFrom-Json).data.ports
        $compatiblePort = $ports | Where-Object {
            $_.status -eq 'ACTIVE' -and $_.connector_type -eq $vehicle.connector_type
        } | Select-Object -First 1
        if ($compatiblePort) {
            $candidate
            break
        }
    }
    if (-not $station) {
        throw 'Không tìm thấy trạm ACTIVE có cổng tương thích với xe demo'
    }

    $now = [DateTimeOffset]::UtcNow
    $arrival = $now.AddMinutes(30 - ($now.Minute % 15)).AddSeconds(-$now.Second)
    $arrival = $arrival.AddTicks(-($arrival.Ticks % [TimeSpan]::TicksPerSecond))
    $horizonEnd = $arrival.AddMinutes(-30).AddHours(24)
    $state.booking = @{
        user_id         = $state.userId
        vehicle_id      = $vehicle.vehicle_id
        station_id      = $station.station_id
        soc_now         = 30
        soc_target      = 45
        idempotency_key = "smoke-$([Guid]::NewGuid().ToString('N'))"
    }
    # Backend đọc khóa từ JSON. Gửi cùng giá trị trong header để kiểm tra replay.
    $state.bookingHeaders = $state.authHeaders.Clone()
    $state.bookingHeaders['Idempotency-Key'] = $state.booking.idempotency_key
    # Thử khung tiếp theo chỉ khi backend xác nhận chưa tạo lịch vì trùng giờ.
    while ($arrival.AddHours(2) -le $horizonEnd) {
        $departure = $arrival.AddHours(2)
        $state.booking.arrival_time = $arrival.ToString('o')
        $state.booking.departure_time = $departure.ToString('o')
        $response = Invoke-Api "$backend/api/v1/requests" -Method POST -Headers $state.bookingHeaders -Body $state.booking
        if ($response.StatusCode -ne 409 -or ($response.Content | ConvertFrom-Json).detail -notmatch 'overlapping that time window') {
            break
        }
        $arrival = $departure
    }
    Assert-Status $response 200
    $booking = $response.Content | ConvertFrom-Json
    if (-not $booking.request_id) {
        throw 'HTTP 200 nhưng thiếu request_id'
    }
    $state.requestId = $booking.request_id

    if ($booking.explanation -isnot [string] -or $booking.explanation -notmatch '[ăâđêôơưà-ãè-éì-íò-õù-úý\u1EA0-\u1EF9]') {
        throw "HTTP 200, request_id=$($state.requestId), thiếu explanation tiếng Việt"
    }
    "HTTP 200, request_id=$($state.requestId), có explanation tiếng Việt"
}

Invoke-Check 6 'Đặt lịch vượt 24 giờ' {
    Assert-Login
    if (-not $state.booking) {
        throw 'Chưa có dữ liệu đặt lịch từ bước 5'
    }
    $booking = $state.booking.Clone()
    $booking.departure_time = [DateTimeOffset]::UtcNow.AddHours(25).ToString('o')
    $booking.idempotency_key = "smoke-$([Guid]::NewGuid().ToString('N'))"
    $headers = $state.authHeaders.Clone()
    $headers['Idempotency-Key'] = $booking.idempotency_key
    $response = Invoke-Api "$backend/api/v1/requests" -Method POST -Headers $headers -Body $booking
    Assert-Status $response 422
    if (($response.Content | ConvertFrom-Json).detail -notmatch '24 giờ') {
        throw 'HTTP 422 nhưng lỗi trả về không xác nhận giới hạn 24 giờ'
    }
    'HTTP 422, giới hạn 24 giờ'
}

Invoke-Check 7 'Gửi lại Idempotency-Key' {
    Assert-Login
    if (-not $state.requestId) {
        throw 'Bước 5 chưa tạo được request_id để gửi lại'
    }
    $response = Invoke-Api "$backend/api/v1/requests" -Method POST -Headers $state.bookingHeaders -Body $state.booking
    Assert-Status $response 409
    if (($response.Content | ConvertFrom-Json).detail -notmatch 'idempotency[_ ]key') {
        throw 'HTTP 409 nhưng lỗi trả về không xác nhận trùng idempotency_key'
    }
    'HTTP 409, trùng idempotency_key'
}

Invoke-Check 8 'GET /schedule' {
    Assert-Login
    if (-not $state.requestId) {
        throw 'Bước 5 chưa tạo được request_id để đọc lịch'
    }
    $response = Invoke-Api "$backend/api/v1/requests/$($state.requestId)/schedule" -Headers $state.authHeaders
    Assert-Status $response 200
    $schedule = $response.Content | ConvertFrom-Json -AsHashtable
    $missing = @('solver_status', 'algorithm', 'solve_ms', 'explanation' | Where-Object {
        -not $schedule.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$schedule[$_])
    })
    if ($missing.Count) {
        throw "HTTP 200, thiếu trường $($missing -join ', ')"
    }
    "HTTP 200, solver_status=$($schedule.solver_status), algorithm=$($schedule.algorithm), solve_ms=$($schedule.solve_ms), có explanation"
}

Invoke-Check 9 'CORS preflight' {
    $origin = 'https://ev-sharegrid.web.app'
    $response = Invoke-Api "$backend/api/v1/requests" -Method OPTIONS -Headers @{
        Origin                           = $origin
        'Access-Control-Request-Method'  = 'POST'
        'Access-Control-Request-Headers' = 'authorization,content-type,idempotency-key'
    }
    Assert-Status $response 200
    if (($response.Headers['Access-Control-Allow-Origin'] -join ',') -cne $origin) {
        throw "HTTP 200 nhưng Access-Control-Allow-Origin không khớp $origin"
    }
    "HTTP 200, origin=$origin"
}

Invoke-Check 10 'Benchmark Trang 20' {
    $sample = Join-Path $PSScriptRoot '../ai_engine/samples/page20_input.json'
    # Giữ nguyên múi giờ trong snapshot thay vì chuyển ngày giờ qua kiểu DateTime.
    $snapshot = Get-Content -LiteralPath $sample -Raw -Encoding UTF8
    $payload = '{"scenario_id":"page20","algorithms":["MILP_MPC"],"repeats":1,"snapshot":' + $snapshot + '}'
    $response = Invoke-Api "$aiEngine/ai/benchmark" -Method POST -Body $payload
    Assert-Status $response 200
    $benchmark = $response.Content | ConvertFrom-Json
    $run = $benchmark.results[0].result
    $cost = $run.kpi.total_cost_vnd
    if ($null -eq $cost -or [decimal]$cost -ne 5500.0) {
        throw "HTTP 200, total_cost_vnd=$cost, kỳ vọng 5500.0"
    }
    "HTTP 200, total_cost_vnd=$($cost.ToString('0.0', [cultureinfo]::InvariantCulture)), $($run.algorithm) / $($run.status)"
}

$passCount = @($results | Where-Object { $_ -eq 'PASS' }).Count
$failCount = $results.Count - $passCount
Write-Host ''
Write-Host 'Tổng kết'
Write-Host ('{0,5} {1,5} {2,5}' -f 'PASS', 'FAIL', 'TOTAL')
Write-Host ('{0,5} {1,5} {2,5}' -f $passCount, $failCount, $results.Count)
if ($failCount -gt 0) {
    exit 1
}
exit 0
