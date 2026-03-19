@echo off
setlocal enabledelayedexpansion

echo ========================================
echo LaTeX Compilation Script
echo ========================================
echo.

:CLEAN
echo [1/5] Cleaning auxiliary files...
del /Q *.aux *.out *.toc *.fls *.fdb_latexmk *.synctex* *.bcf *.run.xml *.blg *.bbl 2>nul
timeout /t 1 /nobreak >nul
echo       Done.
echo.

:COMPILE
echo [2/5] Running pdflatex (first pass)...
pdflatex -interaction=nonstopmode report.tex >nul 2>&1

if not exist report.pdf (
    echo       ERROR: First pdflatex pass failed.
    echo       Check report.log for details.
    goto END
)
echo       Done.
echo.

echo [3/5] Running biber to process bibliography...
biber report >nul 2>&1
echo       Done.
echo.

echo [4/5] Running pdflatex (second pass)...
pdflatex -interaction=nonstopmode report.tex >nul 2>&1
echo       Done.
echo.

echo [5/5] Running pdflatex (final pass)...
pdflatex -interaction=nonstopmode report.tex >nul 2>&1

if exist report.pdf (
    echo       Compilation successful!
    goto SUCCESS
) else (
    echo       ERROR: Compilation failed.
    echo       Check report.log for details.
    goto END
)

:SUCCESS
echo.
echo PDF Created Successfully!
echo       Location: %CD%\report.pdf
for %%F in (report.pdf) do (
    set size=%%~zF
    set /a sizeMB=!size! / 1048576
    echo       Size: !sizeMB! MB
    echo       Last Modified: %%~tF
)
echo.
echo ========================================
echo.

:END
pause
