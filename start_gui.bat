@echo off
setlocal
if defined FPT_PYTHON (
  "%FPT_PYTHON%" -u "%~dp0host\gui.py" %*
  if errorlevel 1 goto failed
  exit /b 0
)
if not exist "%~dp0.venv\Scripts\python.exe" (
  python -m venv "%~dp0.venv"
  if errorlevel 1 goto failed
)
"%~dp0.venv\Scripts\python.exe" -c "import numpy, torch, transformers, accelerate" >nul 2>&1
if errorlevel 1 (
  "%~dp0.venv\Scripts\python.exe" -m pip install -r "%~dp0requirements.txt"
  if errorlevel 1 goto failed
)
"%~dp0.venv\Scripts\python.exe" -u "%~dp0host\gui.py" %*
if errorlevel 1 goto failed
exit /b 0
:failed
pause
exit /b 1
