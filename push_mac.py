import subprocess
import os
from pathlib import Path
import shutil

# Use the directory of this script as the repo path (override with REPO_PATH if provided)
repo_path = Path(os.environ.get('REPO_PATH', Path(__file__).resolve().parent))

# Navigate to the repository
os.chdir(repo_path)

def ensure_git_available():
    if shutil.which('git') is None:
        print("Error: 'git' is not installed or not on PATH.")
        raise SystemExit(1)

def changes_pending():
    # Check if there is anything to commit after staging
    result = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True, check=True)
    return bool(result.stdout.strip())

def get_current_branch():
    result = subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], capture_output=True, text=True, check=True)
    return result.stdout.strip()

# Stage all changes (use git add .)
def git_add():
    print("Staging changes...")
    subprocess.run(['git', 'add', '.'], check=True)

# Commit changes with a message
def git_commit(commit_message):
    print(f"Committing changes: {commit_message}")
    subprocess.run(['git', 'commit', '-m', commit_message], check=True)

# Push changes to GitHub (current branch)
def git_push(branch='HEAD'):
    print(f"Pushing changes to GitHub (branch: {branch})...")
    subprocess.run(['git', 'push', '-u', 'origin', branch], check=True)

# Main function to run the script
def push_changes(commit_message="Updated files"):
    try:
        ensure_git_available()
        git_add()
        if not changes_pending():
            print("No changes to commit.")
            return
        git_commit(commit_message)
        branch = get_current_branch()
        git_push(branch)
        print("Changes successfully pushed to GitHub.")
    except subprocess.CalledProcessError as e:
        print(f"Error occurred: {e}")

# Run the script
if __name__ == "__main__":
    message = input("Enter your commit message: ")  # Prompt for commit message
    push_changes(message)
