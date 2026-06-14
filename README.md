# Workflow Visualizer & Orchestrator

This repository contains the installers to set up the 3D workflow visualizer. It makes Antigravity act as the orchestrator, delegating coding tasks to a Claude agent.

## What's inside
- **`install-workflow.ps1`**: The main PowerShell installer. It installs the backend, frontend, orchestration runner (`orchestrate.js`), and default rules files to `%USERPROFILE%\custom-workflow`.
- **`init-workflow.bat`**: Copy this helper script to any of your coding projects to spin up the local visualizer servers and open the 3D map at `http://localhost:3000`.

## Installation
Run the installer to set everything up:
```powershell
./install-workflow.ps1
```

## How to use it
1. Copy `init-workflow.bat` to the root folder of the project you are working on.
2. Run it once to start the visualizer.
3. Once the webpage opens, **close it**. The agent will open it again automatically when it starts.
4. **Important**: You must explicitly instruct the agent in your prompt to read the generated rule markdown file (e.g. `GEMINI.md`) and follow its instructions.

## Customizing agents
You can configure which agent plays which role by changing the name of the generated markdown rule file and adjusting the instructions in the prompt.

## How the 3D Map Works
The dashboard at `http://localhost:3000` is a real-time interactive 3D graph representing your project's directory structure:
- **Visuals**: Folders and files are represented as nodes. Active agents light up paths from the root to their current files (green for Antigravity, purple for Claude).
- **Search & Stats**: The top bar displays overall file and folder counts, along with a file search bar.
- **Agent Panel**: Displays each agent's current active file and status (e.g., `thinking`, `coding`, `planning`).
- **Detail Panel**: Clicking a file node or search result shows its size, status badge, exported functions/classes, and notes left by agents.

## How Agents Use the Map
Agents interact with the map automatically using the `orchestrate.js` script to coordinate and save context tokens:
1. **Status Tracking**: The orchestrator updates the agent's node and status as they work.
2. **Reading Notes (Token Saving)**: Before opening a file, agents query its node notes using `--query=node` to understand what it does and exports without reading the full file.
3. **Writing Notes**: After modifying a file, the agent writes a concise one-line note summarizing their changes to guide the next agent.
