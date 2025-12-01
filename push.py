import subprocess
import os

# Path to your local Git repository
repo_path = r'c:\Dropbox\Settings\Rive'  # Modify this to your repo's path

# Navigate to the repository
os.chdir(repo_path)

# Stage all changes (use git add .)
def git_add():
    print("Staging changes...")
    subprocess.run(['git', 'add', '.'], check=True)

# Commit changes with a message
def git_commit(commit_message):
    print(f"Committing changes: {commit_message}")
    subprocess.run(['git', 'commit', '-m', commit_message], check=True)

# Push changes to GitHub
def git_push():
    print("Pushing changes to GitHub...")
    subprocess.run(['git', 'push', 'origin', 'main'], check=True)

# Main function to run the script
def push_changes(commit_message="Updated files"):
    try:
        git_add()
        git_commit(commit_message)
        git_push()
        print("Changes successfully pushed to GitHub.")
    except subprocess.CalledProcessError as e:
        print(f"Error occurred: {e}")

# Run the script
if __name__ == "__main__":
    message = input("Enter your commit message: ")  # Prompt for commit message
    push_changes(message)
