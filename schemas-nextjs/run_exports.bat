@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ---------- Config ----------
set "PSQL_FILE=export_full_schema_logic.psql"
set "SCHEMA=public"

REM Local DB
set "LOCAL_HOST=localhost"
set "LOCAL_PORT=5432"
set "LOCAL_DB=earnlayer_app"
set "LOCAL_USER=postgres"

REM Cloud DB
set "CLOUD_HOST=yamabiko.proxy.rlwy.net"
set "CLOUD_PORT=18490"
set "CLOUD_DB=railway"
set "CLOUD_USER=postgres"

REM Output dirs
set "DEV_DIR=local"
set "PROD_DIR=cloud"
REM ----------------------------

where psql >nul 2>nul || (echo psql not found in PATH & exit /b 1)
where pg_dump >nul 2>nul || (echo pg_dump not found in PATH & exit /b 1)

if not exist "%DEV_DIR%" mkdir "%DEV_DIR%"
if not exist "%PROD_DIR%" mkdir "%PROD_DIR%"

REM ---- Helper: atomic dump using pg_dump -f + copy /Y ----
REM usage: call :dump_file "OUTFILE" [remaining pg_dump args...]
goto :after_helpers
:dump_file
set "OUTFILE=%~1"
set "TMPFILE=%OUTFILE%.tmp.%RANDOM%%RANDOM%"

REM Ensure any old temp is gone
if exist "%TMPFILE%" del /q "%TMPFILE%" >nul 2>&1

REM Shift to remove the OUTFILE from the arguments
shift

REM Now build the command with all remaining arguments
REM We need to explicitly build the argument list after shift
set "DUMP_ARGS="
:build_args
if "%~1"=="" goto :done_args
set "DUMP_ARGS=%DUMP_ARGS% %1"
shift
goto :build_args
:done_args

REM Run pg_dump with -f first, then all the args
pg_dump -f "%TMPFILE%" %DUMP_ARGS%
if errorlevel 1 (
  echo Dump failed: pg_dump -f "%TMPFILE%" %DUMP_ARGS%
  if exist "%TMPFILE%" del /q "%TMPFILE%" >nul 2>&1
  exit /b 1
)

REM Overwrite target even if it is currently open read-only in editors
copy /Y "%TMPFILE%" "%OUTFILE%" >nul
if errorlevel 1 (
  echo Failed to overwrite "%OUTFILE%". Close any app locking it and retry.
  del /q "%TMPFILE%" >nul 2>&1
  exit /b 1
)

del /q "%TMPFILE%" >nul 2>&1
exit /b 0
:after_helpers
REM --------------------------------------------------------

echo Connecting to Local DB...
set /p LOCAL_PGPASS=Enter Local DB password: 

set "PGPASSWORD=%LOCAL_PGPASS%"

psql -q -U "%LOCAL_USER%" -h "%LOCAL_HOST%" -p "%LOCAL_PORT%" -d "%LOCAL_DB%" ^
  -v outdir="%DEV_DIR%" -v schema="%SCHEMA%" ^
  -f "%PSQL_FILE%"
if errorlevel 1 (set "PGPASSWORD=" & exit /b 1)

echo Dumping Local schema only to %DEV_DIR%\schema.sql...
call :dump_file "%DEV_DIR%\schema.sql" -U "%LOCAL_USER%" -h "%LOCAL_HOST%" -p "%LOCAL_PORT%" -s "%LOCAL_DB%"
if errorlevel 1 (set "PGPASSWORD=" & exit /b 1)

echo Dumping Local schema with data to %DEV_DIR%\schema_w_data.sql...
call :dump_file "%DEV_DIR%\schema_w_data.sql" -U "%LOCAL_USER%" -h "%LOCAL_HOST%" -p "%LOCAL_PORT%" "%LOCAL_DB%"
if errorlevel 1 (set "PGPASSWORD=" & exit /b 1)

set "PGPASSWORD="

echo.
echo Connecting to Cloud DB...
set /p CLOUD_PGPASS=Enter Cloud DB password: 

set "PGPASSWORD=%CLOUD_PGPASS%"

psql -q -U "%CLOUD_USER%" -h "%CLOUD_HOST%" -p "%CLOUD_PORT%" -d "%CLOUD_DB%" ^
  -v outdir="%PROD_DIR%" -v schema="%SCHEMA%" ^
  -f "%PSQL_FILE%"
if errorlevel 1 (set "PGPASSWORD=" & exit /b 1)

echo Dumping Cloud schema only to %PROD_DIR%\cloud_schema.sql...
call :dump_file "%PROD_DIR%\cloud_schema.sql" -U "%CLOUD_USER%" -h "%CLOUD_HOST%" -p "%CLOUD_PORT%" -s "%CLOUD_DB%"
if errorlevel 1 (set "PGPASSWORD=" & exit /b 1)

echo Dumping Cloud schema with data to %PROD_DIR%\cloud_schema_w_data.sql...
call :dump_file "%PROD_DIR%\cloud_schema_w_data.sql" -U "%CLOUD_USER%" -h "%CLOUD_HOST%" -p "%CLOUD_PORT%" "%CLOUD_DB%"
if errorlevel 1 (set "PGPASSWORD=" & exit /b 1)

set "PGPASSWORD="
echo.
echo All exports completed.
endlocal