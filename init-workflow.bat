@echo off
set "projPath=%cd%"
set "installDir=%USERPROFILE%\custom-workflow\agent-workflow-visualizer"

echo ==========================================================
echo    INITIALISATION WORKFLOW MULTI-AGENT DANS CE PROJET
echo ==========================================================
echo Projet : %projPath%

:: La confiance du dossier et les permissions de Claude Code sont gerees
:: automatiquement au lancement de l'agent (--dangerously-skip-permissions
:: + pre-acceptation dans ~/.claude.json par orchestrate.js).
echo [*] Confiance du dossier geree automatiquement au lancement de Claude.

:: Copie locale de la regle dans GEMINI.md (lu automatiquement par Gemini/Antigravity)
copy /y "%USERPROFILE%\custom-workflow\.antigravityrules" "%projPath%\GEMINI.md" >nul
echo [+] Fichier de regles GEMINI.md cree a la racine du projet.

:: Creation ou mise a jour du .gitignore local (exclut les regles et le batch, sauf la map)
set "gitIgnoreFile=%projPath%\.gitignore"
if not exist "%gitIgnoreFile%" (
    echo # Antigravity multi-agent workflow > "%gitIgnoreFile%"
    echo GEMINI.md >> "%gitIgnoreFile%"
    echo init-workflow.bat >> "%gitIgnoreFile%"
    echo .claude-exit-code.txt >> "%gitIgnoreFile%"
    echo [+] Fichier .gitignore cree et fichiers de workflow ignores.
) else (
    :: Verification et ajout individuel de chaque fichier si absent
    findstr /c:"GEMINI.md" "%gitIgnoreFile%" >nul
    if errorlevel 1 (
        echo. >> "%gitIgnoreFile%"
        echo GEMINI.md >> "%gitIgnoreFile%"
        echo [+] GEMINI.md ajoute a .gitignore.
    )
    findstr /c:"init-workflow.bat" "%gitIgnoreFile%" >nul
    if errorlevel 1 (
        echo init-workflow.bat >> "%gitIgnoreFile%"
        echo [+] init-workflow.bat ajoute a .gitignore.
    )
    findstr /c:".claude-exit-code.txt" "%gitIgnoreFile%" >nul
    if errorlevel 1 (
        echo .claude-exit-code.txt >> "%gitIgnoreFile%"
        echo [+] .claude-exit-code.txt ajoute a .gitignore.
    )
)

:: Demarrage du visualiseur backend et frontend en CMD natif (rapide, sans bug de quotes ni blocage)
echo [*] Demarrage du serveur de visualisation...
start /b /d "%installDir%\backend" cmd /c node server.js "%projPath%"
start /b /d "%installDir%\frontend" cmd /c npm run dev

:: Ouverture du navigateur avec un ping d'attente compatible avec la redirection
ping -n 4 127.0.0.1 >nul
start http://localhost:3000
echo [+] Graphe 3D et Agents initialises !
cmd /k