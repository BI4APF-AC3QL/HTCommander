param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'build'))
$ErrorActionPreference = 'Stop'
$version = '2.11.4'
$expected = 'cd5ccfd86a4b40732cf715890d0dca5bf3f63adefec5a7914de85adf240c60ce7e5d2791631b88ef9758e46b23bb1730e020b9c5d696889740b284ffd4788e35'
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$archive = Join-Path $OutputDirectory "caddy_${version}_windows_amd64.zip"
if (-not (Test-Path $archive)) {
    Invoke-WebRequest "https://github.com/caddyserver/caddy/releases/download/v$version/caddy_${version}_windows_amd64.zip" -OutFile $archive
}
if ((Get-FileHash $archive -Algorithm SHA512).Hash.ToLowerInvariant() -ne $expected) { throw 'Caddy official asset SHA512 mismatch' }
$caddyDirectory = Join-Path $OutputDirectory 'caddy'
Expand-Archive $archive -DestinationPath $caddyDirectory -Force
$payload = Join-Path $OutputDirectory 'caddy.gz'
$inputStream = [IO.File]::OpenRead((Join-Path $caddyDirectory 'caddy.exe'))
$outputStream = [IO.File]::Create($payload)
$gzip = New-Object IO.Compression.GZipStream($outputStream, [IO.Compression.CompressionMode]::Compress)
try { $inputStream.CopyTo($gzip) } finally { $gzip.Dispose(); $outputStream.Dispose(); $inputStream.Dispose() }
$hash = (Get-FileHash (Join-Path $caddyDirectory 'caddy.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Gateway.cs')).Replace('PAYLOAD_HASH', $hash)
$generated = Join-Path $OutputDirectory 'Gateway.build.cs'
[IO.File]::WriteAllText($generated, $source, (New-Object Text.UTF8Encoding($false)))
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$exe = Join-Path $OutputDirectory 'HTCommander-HTTPS-Gateway.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ "/out:$exe" "/resource:$payload,caddy.gz" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $generated
if ($LASTEXITCODE -ne 0) { throw 'Gateway compilation failed' }
$selfTest = Start-Process -FilePath $exe -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
if ($selfTest.ExitCode -ne 0) { throw "Gateway self-test failed: $($selfTest.ExitCode)" }
$adapted = [IO.File]::ReadAllText((Join-Path $OutputDirectory 'HTCommander-Gateway-Data/self-test.txt'))
if (-not $adapted.Contains('127.0.0.1:18080') -or -not $adapted.Contains('radio.example.com') -or -not $adapted.Contains('same-origin')) { throw 'Unexpected adapted gateway configuration' }
Copy-Item (Join-Path $caddyDirectory 'LICENSE') (Join-Path $OutputDirectory 'CADDY-LICENSE.txt')
Write-Output "Built and verified: $exe"
