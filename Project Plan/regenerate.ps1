$pdflatex = "C:\texlive\2025\bin\windows\pdflatex.exe"
$projectDir = "D:\Fontys\S7\Project Plan"

Set-Location $projectDir

Write-Host "Cleaning auxiliary files..." -ForegroundColor Cyan
Remove-Item report.pdf, report.aux, report.log, report.toc, report.out, report.bcf, report.bbl, report.blg, report.run.xml -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

Write-Host "Running pdflatex (pass 1)..." -ForegroundColor Cyan
& $pdflatex -interaction=nonstopmode report.tex
Start-Sleep -Seconds 1

Write-Host "Running pdflatex (pass 2)..." -ForegroundColor Cyan
& $pdflatex -interaction=nonstopmode report.tex
Start-Sleep -Seconds 1

if (Test-Path "report.pdf") {
    Write-Host "Done! report.pdf generated successfully." -ForegroundColor Green
} else {
    Write-Host "ERROR: Compilation failed. Check report.log for details." -ForegroundColor Red
}

Read-Host "Press Enter to exit"
