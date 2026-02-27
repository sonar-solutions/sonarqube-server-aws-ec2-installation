#!/usr/bin/env python3
"""
Terraform JSON Variables Interactive Editor

This script reads terraform.tfvars.json file (or creates it from terraform.tfvars.json.example 
if it doesn't exist), prompts user to modify each variable value, and updates the file with 
the new values.

Usage:
  python3 update_variables.py

The script will:
1. Look for terraform.tfvars.json first
2. If not found, use terraform.tfvars.json.example as a template
3. Allow interactive editing of all variables
4. Save the result to terraform.tfvars.json
"""

import json
import os
import sys
from typing import Dict, Any


def load_json_variables(file_path: str) -> Dict[str, Any]:
    """Load variables from JSON file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"❌ Error: {file_path} not found.")
        return {}
    except json.JSONDecodeError as e:
        print(f"❌ Error: Invalid JSON in {file_path}: {e}")
        return {}


def format_value_for_display(value: Any) -> str:
    """Format value for display to user."""
    if isinstance(value, str):
        return value
    elif isinstance(value, list):
        return ", ".join(str(item) for item in value)
    else:
        return str(value)


def parse_user_input(user_input: str, current_value: Any) -> Any:
    """Parse user input based on the type of current value."""
    user_input = user_input.strip()
    
    if isinstance(current_value, str):
        return user_input
    elif isinstance(current_value, list):
        # Try to parse as JSON first
        try:
            parsed = json.loads(user_input)
            if isinstance(parsed, list):
                return parsed
        except json.JSONDecodeError:
            pass
        
        # If not JSON, treat as comma-separated values
        if ',' in user_input:
            return [item.strip() for item in user_input.split(',')]
        else:
            return [user_input]
    elif isinstance(current_value, bool):
        return user_input.lower() in ['true', '1', 'yes', 'y', 'on']
    elif isinstance(current_value, (int, float)):
        try:
            if isinstance(current_value, int):
                return int(user_input)
            else:
                return float(user_input)
        except ValueError:
            raise ValueError(f"Invalid number: {user_input}")
    else:
        return user_input


def save_json_variables(file_path: str, variables: Dict[str, Any]) -> bool:
    """Save variables to JSON file with pretty formatting."""
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(variables, f, indent=2, ensure_ascii=False)
        return True
    except Exception as e:
        print(f"❌ Error saving file: {e}")
        return False


def determine_source_file() -> str:
    """
    Determine which file to use as the source for variables.
    
    Returns:
        str: Path to the source file to read variables from
        
    Exits:
        If neither terraform.tfvars.json nor terraform.tfvars.json.example exists
    """
    variables_file = 'terraform.tfvars.json'
    example_file = 'terraform.tfvars.json.example'
    
    # Check if main variables file exists
    if not os.path.exists(variables_file):
        print(f"📄 {variables_file} not found.")
        
        # Check if example file exists
        if os.path.exists(example_file):
            print(f"📋 Found {example_file}, using it as template.")
            print(f"💡 Will create {variables_file} with your customized values.")
            return example_file
        else:
            print(f"❌ Error: Neither {variables_file} nor {example_file} found in current directory.")
            print(f"Current directory: {os.getcwd()}")
            print("\n💡 Please create one of these files first:")
            print(f"   - {variables_file} (your actual variables)")
            print(f"   - {example_file} (example template)")
            sys.exit(1)
    else:
        print(f"📁 Found {variables_file}")
        return variables_file


def main():
    """Main function to run the interactive JSON variable editor."""
    variables_file = 'terraform.tfvars.json'
    example_file = 'terraform.tfvars.json.example'
    
    # Determine which file to use as source
    source_file = determine_source_file()
    
    print("🚀 Terraform JSON Variables Interactive Editor")
    print("=" * 55)
    print(f"📁 Reading variables from: {source_file}")
    if source_file == example_file:
        print(f"💾 Will save changes to: {variables_file}")
    print("💡 Press Enter to keep current value, or type new value to change it.")
    print()
    
    try:
        # Load current variables from the source file
        variables = load_json_variables(source_file)
        
        if not variables:
            print("❌ No variables found or file is empty.")
            return
        
        print(f"📋 Found {len(variables)} variables:")
        print()
        
        # Create a copy for modifications
        updated_variables = variables.copy()
        changes_made = []
        
        # Iterate through each variable
        for i, (var_name, current_value) in enumerate(variables.items(), 1):
            print(f"🔧 Variable {i}/{len(variables)}: {var_name}")
            print(f"   Type: {type(current_value).__name__}")
            
            display_value = format_value_for_display(current_value)
            print(f"   Current value: {display_value}")
            
            # Determine prompt based on type
            if isinstance(current_value, list):
                prompt = "   New value (comma-separated or JSON array): "
            elif isinstance(current_value, bool):
                prompt = "   New value (true/false): "
            else:
                prompt = "   New value: "
            
            try:
                user_input = input(prompt).strip()
            except KeyboardInterrupt:
                print("\n\n❌ Operation cancelled by user.")
                return
            
            # Process user input
            if user_input:  # User provided a value
                try:
                    new_value = parse_user_input(user_input, current_value)
                    
                    if new_value != current_value:
                        updated_variables[var_name] = new_value
                        changes_made.append({
                            'name': var_name,
                            'old': display_value,
                            'new': format_value_for_display(new_value)
                        })
                        print(f"   ✅ Updated: {var_name}")
                    else:
                        print("   ℹ️  No change: same value")
                        
                except Exception as e:
                    print(f"   ❌ Error parsing input: {e}")
                    print(f"   ℹ️  Skipping {var_name}")
            else:
                print("   ℹ️  Keeping current value")
            
            print()
        
        # Summary and confirmation
        if changes_made:
            print("📝 Summary of Changes:")
            print("-" * 30)
            for change in changes_made:
                print(f"• {change['name']}: '{change['old']}' → '{change['new']}'")
            print()
            
            # Confirm changes
            if source_file == example_file:
                confirm = input(f"💾 Create {variables_file} with these values? (y/N): ").strip().lower()
            else:
                confirm = input(f"💾 Apply these changes to {variables_file}? (y/N): ").strip().lower()
            
            if confirm in ['y', 'yes']:
                # Create backup only if we're modifying an existing file
                if source_file == variables_file and os.path.exists(variables_file):
                    backup_file = f"{variables_file}.backup"
                    if save_json_variables(backup_file, variables):
                        print(f"💾 Backup created: {backup_file}")
                
                # Write updated variables to the main file
                if save_json_variables(variables_file, updated_variables):
                    if source_file == example_file:
                        print(f"✅ Successfully created {variables_file} from template")
                    else:
                        print(f"✅ Successfully updated {variables_file}")
                    print(f"🔄 {len(changes_made)} variables were modified")
                else:
                    print("❌ Failed to save changes")
            else:
                print("❌ Changes discarded")
        else:
            # No changes were made
            if source_file == example_file:
                # If we're using the example file but made no changes, still offer to create the main file
                print("ℹ️  No changes were made to the example values.")
                create_anyway = input(f"💾 Create {variables_file} with default values anyway? (y/N): ").strip().lower()
                
                if create_anyway in ['y', 'yes']:
                    if save_json_variables(variables_file, variables):
                        print(f"✅ Successfully created {variables_file} from template")
                        print("ℹ️  All variables kept their example values")
                    else:
                        print("❌ Failed to create file")
                else:
                    print("ℹ️  No file created")
            else:
                print("ℹ️  No changes were made")
        
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
