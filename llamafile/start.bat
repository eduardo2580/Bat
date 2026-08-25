@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Qwen3 Llamafile Launcher

rem ============================================================
rem QWEN3 LLAMAFILE SMART LAUNCHER
rem Tested design target: llamafile 0.10.5 on Windows 10/11
rem ============================================================

set "BASE=%~dp0"
cd /d "%BASE%"

set "LLAMAFILE=%BASE%llamafile-0.10.5.exe"
set "MODELS_DIR=%BASE%models"
set "LOG_DIR=%BASE%logs"
set "CONFIG=%BASE%config.bat"
set "DEFAULT_PORT=8080"
set "HOST=127.0.0.1"
set "AUTO_BROWSER=1"
set "RESTART_ON_CRASH=0"
set "MAX_RESTARTS=3"
set "API_KEY="
set "TEMPERATURE=0.6"
set "TOP_P=0.95"
set "TOP_K=20"
set "REPEAT_PENALTY=1.05"
set "MAX_TOKENS=2048"
set "REASONING_BUDGET=8192"
set "LAN_MODE=0"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
if not exist "%MODELS_DIR%" mkdir "%MODELS_DIR%" >nul 2>&1

rem ------------------------------------------------------------
rem Load user configuration if present
rem ------------------------------------------------------------
if exist "%CONFIG%" call "%CONFIG%"

rem ------------------------------------------------------------
rem Find llamafile executable
rem ------------------------------------------------------------
if not exist "%LLAMAFILE%" (
    for %%F in ("%BASE%llamafile*.exe") do (
        if exist "%%~fF" (
            set "LLAMAFILE=%%~fF"
            goto :exe_found
        )
    )
)
:exe_found

if not exist "%LLAMAFILE%" (
    call :error "llamafile executable was not found in %BASE%"
    echo Put llamafile-0.10.5.exe next to this BAT.
    pause
    exit /b 1
)

for %%F in ("%LLAMAFILE%") do set "PROCESS_NAME=%%~nxF"

rem ------------------------------------------------------------
rem Check llamafile version
rem ------------------------------------------------------------
echo.
echo ============================================================
echo              QWEN3 LLAMAFILE SMART LAUNCHER
echo ============================================================
echo.
echo Executable: %LLAMAFILE%
echo.

"%LLAMAFILE%" --version >"%TEMP%\llamafile_version.txt" 2>&1
set "VERSION_TEXT="
set /p VERSION_TEXT=<"%TEMP%\llamafile_version.txt"
if defined VERSION_TEXT echo Version:   !VERSION_TEXT!

rem ------------------------------------------------------------
rem Hardware detection
rem ------------------------------------------------------------
echo.
echo [1/6] Detecting hardware...

for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty NumberOfCores)" 2^>nul`) do set "CPU_CORES=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty NumberOfLogicalProcessors)" 2^>nul`) do set "CPU_THREADS=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)" 2^>nul`) do set "RAM_GB=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)" 2^>nul`) do set "CPU_NAME=%%A"

if not defined CPU_CORES set "CPU_CORES=4"
if not defined CPU_THREADS set "CPU_THREADS=%CPU_CORES%"
if not defined RAM_GB set "RAM_GB=8"
if not defined CPU_NAME set "CPU_NAME=Unknown CPU"

rem NVIDIA detection
set "NVIDIA=0"
set "NVIDIA_NAME="
set "NVIDIA_VRAM=0"
where nvidia-smi >nul 2>&1
if not errorlevel 1 (
    for /f "usebackq delims=" %%A in (`nvidia-smi --query-gpu=name --format=csv,noheader 2^>nul`) do (
        if not defined NVIDIA_NAME set "NVIDIA_NAME=%%A"
    )
    for /f "usebackq delims=" %%A in (`nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2^>nul`) do (
        if "!NVIDIA_VRAM!"=="0" set "NVIDIA_VRAM=%%A"
    )
    if defined NVIDIA_NAME set "NVIDIA=1"
)

rem Detect display adapters for AMD / Intel / generic Vulkan
set "GPU_LIST="
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-CimInstance Win32_VideoController | Where-Object {$_.Name} | ForEach-Object {$_.Name})" 2^>nul`) do (
    if defined GPU_LIST (
        set "GPU_LIST=!GPU_LIST! ^| %%A"
    ) else (
        set "GPU_LIST=%%A"
    )
)

set "AMD=0"
set "INTEL=0"
echo(!GPU_LIST! | findstr /i "AMD Radeon" >nul && set "AMD=1"
echo(!GPU_LIST! | findstr /i "Intel Arc Intel UHD Intel Iris" >nul && set "INTEL=1"

echo.
echo CPU:        %CPU_NAME%
echo Cores:      %CPU_CORES%
echo Threads:    %CPU_THREADS%
echo RAM:        %RAM_GB% GB
echo GPU(s):     %GPU_LIST%
if "%NVIDIA%"=="1" echo NVIDIA VRAM: %NVIDIA_VRAM% MB
echo.

rem ------------------------------------------------------------
rem Select model
rem ------------------------------------------------------------
echo [2/6] Selecting model...
echo.

set "MODEL="
set /a MODEL_COUNT=0

for /f "delims=" %%F in ('dir /b /a:-d "%MODELS_DIR%\*.gguf" 2^>nul') do (
    set /a MODEL_COUNT+=1
    set "MODEL_!MODEL_COUNT!=%MODELS_DIR%\%%F"
    echo   !MODEL_COUNT!^) %%F
)

for /f "delims=" %%F in ('dir /b /a:-d "%BASE%*.gguf" 2^>nul') do (
    set /a MODEL_COUNT+=1
    set "MODEL_!MODEL_COUNT!=%BASE%%%F"
    echo   !MODEL_COUNT!^) %%F
)

if "%MODEL_COUNT%"=="0" (
    call :error "No .gguf model was found."
    echo Put your GGUF in this folder or in:
    echo %MODELS_DIR%
    pause
    exit /b 1
)

if "%MODEL_COUNT%"=="1" (
    set "MODEL=!MODEL_1!"
) else (
    set /p "MODEL_CHOICE=Choose model [1-%MODEL_COUNT%]: "
    if not defined MODEL_CHOICE set "MODEL_CHOICE=1"
    set "MODEL=!MODEL_%MODEL_CHOICE%!"
)

if not defined MODEL (
    call :error "Invalid model selection."
    pause
    exit /b 1
)

for %%F in ("%MODEL%") do (
    set "MODEL_NAME=%%~nxF"
    set "MODEL_SIZE=%%~zF"
)

echo.
echo Model:      %MODEL_NAME%
echo Size:       %MODEL_SIZE% bytes
echo.

rem ------------------------------------------------------------
rem Choose performance profile
rem ------------------------------------------------------------
echo [3/6] Performance profile
echo.
echo   1 - FAST      : lower context, aggressive GPU offload
echo   2 - BALANCED  : recommended default
echo   3 - QUALITY   : larger context
echo   4 - CPU ONLY  : no GPU
echo   5 - CUSTOM    : choose values manually
echo.

set "PROFILE="
set /p "PROFILE=Select profile [1-5, default 2]: "
if not defined PROFILE set "PROFILE=2"

if "%PROFILE%"=="1" goto :profile_fast
if "%PROFILE%"=="2" goto :profile_balanced
if "%PROFILE%"=="3" goto :profile_quality
if "%PROFILE%"=="4" goto :profile_cpu
if "%PROFILE%"=="5" goto :profile_custom
goto :profile_balanced

:profile_fast
set "CTX=4096"
set "BATCH=1024"
set "UBATCH=512"
set "FLASH=auto"
set "MAX_TOKENS=1024"
set "MLock=0"
set "THREADS=%CPU_THREADS%"
set "PROFILE_NAME=FAST"
goto :backend_select

:profile_balanced
set "CTX=8192"
set "BATCH=1024"
set "UBATCH=512"
set "FLASH=auto"
set "MAX_TOKENS=2048"
set "MLock=0"
set "THREADS=%CPU_THREADS%"
set "PROFILE_NAME=BALANCED"
goto :backend_select

:profile_quality
set "CTX=16384"
set "BATCH=1024"
set "UBATCH=512"
set "FLASH=auto"
set "MAX_TOKENS=4096"
set "MLock=0"
set "THREADS=%CPU_THREADS%"
set "PROFILE_NAME=QUALITY"
goto :backend_select

:profile_cpu
set "CTX=4096"
set "BATCH=512"
set "UBATCH=256"
set "FLASH=off"
set "MAX_TOKENS=1024"
set "MLock=1"
set "THREADS=%CPU_THREADS%"
set "PROFILE_NAME=CPU ONLY"
set "BACKEND=disable"
set "NGL=0"
goto :server_options

:profile_custom
echo.
set /p "THREADS=CPU threads [%CPU_THREADS%]: "
if not defined THREADS set "THREADS=%CPU_THREADS%"
set /p "CTX=Context size [8192]: "
if not defined CTX set "CTX=8192"
set /p "BATCH=Batch size [1024]: "
if not defined BATCH set "BATCH=1024"
set /p "UBATCH=UBatch size [512]: "
if not defined UBATCH set "UBATCH=512"
set /p "MAX_TOKENS=Max output tokens [2048]: "
if not defined MAX_TOKENS set "MAX_TOKENS=2048"
set /p "REASONING_BUDGET=Thinking budget [8192]: "
if not defined REASONING_BUDGET set "REASONING_BUDGET=8192"
set /p "TEMPERATURE=Temperature [0.6]: "
if not defined TEMPERATURE set "TEMPERATURE=0.6"
set /p "TOP_P=Top-p [0.95]: "
if not defined TOP_P set "TOP_P=0.95"
set /p "TOP_K=Top-k [20]: "
if not defined TOP_K set "TOP_K=20"
set /p "REPEAT_PENALTY=Repeat penalty [1.05]: "
if not defined REPEAT_PENALTY set "REPEAT_PENALTY=1.05"
set /p "FLASH=Flash Attention [auto/on/off]: "
if not defined FLASH set "FLASH=auto"
set "PROFILE_NAME=CUSTOM"
goto :backend_select

:backend_select
echo.
echo [4/6] GPU backend
echo.
echo   1 - AUTO
echo   2 - NVIDIA CUDA
echo   3 - AMD ROCm/HIP
echo   4 - Vulkan
echo   5 - CPU ONLY
echo.

if "%NVIDIA%"=="1" (
    echo Detected NVIDIA: %NVIDIA_NAME% ^(%NVIDIA_VRAM% MB VRAM^)
)
if "%AMD%"=="1" echo Detected AMD GPU.
if "%INTEL%"=="1" echo Detected Intel GPU.

set "BACKEND_CHOICE="
set /p "BACKEND_CHOICE=Select backend [1-5, default 1]: "
if not defined BACKEND_CHOICE set "BACKEND_CHOICE=1"

if "%BACKEND_CHOICE%"=="1" set "BACKEND=auto"
if "%BACKEND_CHOICE%"=="2" set "BACKEND=nvidia"
if "%BACKEND_CHOICE%"=="3" set "BACKEND=amd"
if "%BACKEND_CHOICE%"=="4" set "BACKEND=vulkan"
if "%BACKEND_CHOICE%"=="5" set "BACKEND=disable"

if "%BACKEND%"=="disable" (
    set "NGL=0"
) else (
    rem Maximum offload is requested. llamafile 0.10.5 supports automatic
    rem device fitting; this is preferable to guessing a layer count.
    set "NGL=999"
)

:server_options
rem ------------------------------------------------------------
rem Port / network / browser
rem ------------------------------------------------------------
echo.
echo [5/6] Server options
echo.

set "PORT=%DEFAULT_PORT%"
:port_check
powershell -NoProfile -Command "$p=Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue; if($p){exit 1}else{exit 0}" >nul 2>&1
if errorlevel 1 (
    echo Port %PORT% is already in use.
    set /a PORT+=1
    goto :port_check
)

echo Selected port: %PORT%

if "%LAN_MODE%"=="1" (
    set "HOST=0.0.0.0"
    echo LAN mode: ENABLED
) else (
    set "HOST=127.0.0.1"
    echo LAN mode: LOCAL ONLY
)

echo.
set "BROWSER_CHOICE=%AUTO_BROWSER%"
set /p "BROWSER_CHOICE=Open browser automatically? [Y/n]: "
if /i "%BROWSER_CHOICE%"=="n" set "AUTO_BROWSER=0"
if /i "%BROWSER_CHOICE%"=="no" set "AUTO_BROWSER=0"

echo.
set "LAN_CHOICE="
set /p "LAN_CHOICE=Allow LAN access? [y/N]: "
if /i "%LAN_CHOICE%"=="y" (
    set "LAN_MODE=1"
    set "HOST=0.0.0.0"
) else (
    set "LAN_MODE=0"
    set "HOST=127.0.0.1"
)

rem ------------------------------------------------------------
rem API key
rem ------------------------------------------------------------
set "API_CHOICE="
echo.
set /p "API_CHOICE=Set an API key? [y/N]: "
if /i "%API_CHOICE%"=="y" (
    echo.
    echo NOTE: the API key will be visible while you type it.
    set /p "API_KEY=Enter API key: "
    if defined API_KEY (
        >"%BASE%api-keys.txt" echo %API_KEY%
        echo API key saved to:
        echo %BASE%api-keys.txt
    )
) else if exist "%BASE%api-keys.txt" (
    echo Existing api-keys.txt will be used.
)

rem ------------------------------------------------------------
rem Restart policy
rem ------------------------------------------------------------
set "RESTART_CHOICE="
echo.
set /p "RESTART_CHOICE=Automatically restart after a crash? [y/N]: "
if /i "%RESTART_CHOICE%"=="y" set "RESTART_ON_CRASH=1"

rem ------------------------------------------------------------
rem Build command
rem ------------------------------------------------------------
:build_command
set "TIMESTAMP=%date:~-4%%date:~3,2%%date:~0,2%_%time:~0,2%%time:~3,2%%time:~6,2%"
set "TIMESTAMP=%TIMESTAMP: =0%"
set "LOG_FILE=%LOG_DIR%\llamafile_%TIMESTAMP%.log"

set "CMD_ARGS=--server --host %HOST% --port %PORT% --model "%MODEL%" --threads %THREADS% --threads-batch %THREADS% --ctx-size %CTX% --batch-size %BATCH% --ubatch-size %UBATCH% --n-gpu-layers %NGL% --flash-attn %FLASH% --n-predict %MAX_TOKENS% --temp %TEMPERATURE% --top-p %TOP_P% --top-k %TOP_K% --repeat-penalty %REPEAT_PENALTY% --jinja --reasoning-format deepseek --reasoning-budget %REASONING_BUDGET% --log-file "%LOG_FILE%" --perf --fit on"

if "%BACKEND%"=="nvidia" set "CMD_ARGS=%CMD_ARGS% --gpu nvidia"
if "%BACKEND%"=="amd" set "CMD_ARGS=%CMD_ARGS% --gpu amd"
if "%BACKEND%"=="vulkan" set "CMD_ARGS=%CMD_ARGS% --gpu vulkan"
if "%BACKEND%"=="auto" set "CMD_ARGS=%CMD_ARGS% --gpu auto"
if "%BACKEND%"=="disable" set "CMD_ARGS=%CMD_ARGS% --gpu disable"
if "%MLock%"=="1" set "CMD_ARGS=%CMD_ARGS% --mlock"
if exist "%BASE%api-keys.txt" set "CMD_ARGS=%CMD_ARGS% --api-key-file "%BASE%api-keys.txt""

rem Security: only bind publicly if LAN mode was explicitly enabled.
if "%LAN_MODE%"=="1" (
    echo.
    echo WARNING: LAN mode exposes the server to your local network.
    echo Make sure Windows Firewall and your network are trusted.
)

rem Save exact launch command
(
    echo "%LLAMAFILE%" %CMD_ARGS%
) > "%LOG_DIR%\last_command.txt"

rem ------------------------------------------------------------
rem Summary
rem ------------------------------------------------------------
echo.
echo ============================================================
echo                       CONFIGURATION
echo ============================================================
echo Profile:       %PROFILE_NAME%
echo Model:         %MODEL_NAME%
echo CPU threads:   %THREADS%
echo Context:       %CTX%
echo Batch:         %BATCH%
echo UBatch:        %UBATCH%
echo Flash Attn:    %FLASH%
echo GPU backend:   %BACKEND%
echo GPU layers:    %NGL%
echo MLock:         %MLock%
echo Max tokens:    %MAX_TOKENS%
echo Think budget:  %REASONING_BUDGET%
echo Temperature:   %TEMPERATURE%
echo Top-p:         %TOP_P%
echo Top-k:         %TOP_K%
echo Host:          %HOST%
echo Port:          %PORT%
if exist "%BASE%api-keys.txt" (echo API key:       ENABLED) else (echo API key:       DISABLED)
echo Log:           %LOG_FILE%
echo ============================================================
echo.

set /p "START=Start llamafile? [Y/n]: "
if /i "%START%"=="n" exit /b 0
if /i "%START%"=="no" exit /b 0

rem ------------------------------------------------------------
rem Start / health-check / restart loop
rem ------------------------------------------------------------
set /a RESTART_COUNT=0

:launch
echo.
echo ============================================================
echo Starting llamafile...
echo Web UI: http://127.0.0.1:%PORT%
if "%LAN_MODE%"=="1" echo LAN URL: http://%COMPUTERNAME%:%PORT%
echo API:    http://127.0.0.1:%PORT%/v1
echo Health: http://127.0.0.1:%PORT%/health
echo ============================================================
echo.

echo Starting at %date% %time% >> "%LOG_FILE%"

rem Prevent accidental duplicate server processes.
tasklist /FI "IMAGENAME eq %PROCESS_NAME%" 2>nul | find /I "%PROCESS_NAME%" >nul
if not errorlevel 1 (
    echo.
    echo [ERROR] %PROCESS_NAME% is already running.
    echo Close the existing process or use another launcher.
    pause
    exit /b 1
)

rem Start the server in the background so we can health-check it.
start "Llamafile-Qwen3" /b "%LLAMAFILE%" %CMD_ARGS%

set /a HEALTH_ATTEMPTS=0
:health_loop
set /a HEALTH_ATTEMPTS+=1

powershell -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:%PORT%/health' -TimeoutSec 2; if($r.StatusCode -eq 200){exit 0}else{exit 1} } catch { exit 1 }" >nul 2>&1

if not errorlevel 1 goto :server_ready

tasklist /FI "IMAGENAME eq %PROCESS_NAME%" 2>nul | find /I "%PROCESS_NAME%" >nul
if errorlevel 1 (
    echo.
    echo [ERROR] llamafile exited before the server became ready.
    echo Check the log:
    echo %LOG_FILE%
    echo.
    if "%RESTART_ON_CRASH%"=="1" goto :restart_after_crash
    pause
    exit /b 1
)

if %HEALTH_ATTEMPTS% GEQ 90 (
    echo.
    echo [WARNING] Server is still loading after 90 checks.
    echo The model may simply be loading slowly.
    echo Continuing to monitor...
    goto :server_monitor
)

echo Waiting for model/server... !HEALTH_ATTEMPTS!/90
timeout /t 1 /nobreak >nul
goto :health_loop

:server_ready
echo.
echo ============================================================
echo                    SERVER READY
echo ============================================================
echo Health check: OK
echo Web UI:       http://127.0.0.1:%PORT%
echo API:          http://127.0.0.1:%PORT%/v1
echo Log:          %LOG_FILE%
echo ============================================================
echo.

if "%AUTO_BROWSER%"=="1" (
    start "" "http://127.0.0.1:%PORT%"
)

:server_monitor
echo Monitoring llamafile. Press Ctrl+C to stop this launcher.
echo.

:monitor_loop
tasklist /FI "IMAGENAME eq %PROCESS_NAME%" 2>nul | find /I "%PROCESS_NAME%" >nul
if errorlevel 1 goto :server_exited

timeout /t 3 /nobreak >nul
goto :monitor_loop

:server_exited
echo.
echo ============================================================
echo Llamafile process has stopped.
echo Stopped at %date% %time% >> "%LOG_FILE%"
echo ============================================================

if "%RESTART_ON_CRASH%"=="1" goto :restart_after_crash

echo.
echo Log file:
echo %LOG_FILE%
echo.
pause
exit /b 0

:restart_after_crash
set /a RESTART_COUNT+=1
if %RESTART_COUNT% LEQ %MAX_RESTARTS% (
    echo Restart attempt %RESTART_COUNT%/%MAX_RESTARTS% in 3 seconds...
    timeout /t 3 /nobreak >nul
    goto :launch
)

echo Maximum restart attempts reached.
echo.
pause
exit /b 1

rem ============================================================
rem Functions
rem ============================================================

:error
echo.
echo [ERROR] %~1
echo.
exit /b
