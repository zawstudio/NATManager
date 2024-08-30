# NAT Manager

NAT Manager is a Bash script designed to simplify the management of Network Address Translation (NAT) rules in IPTables.
This script is ideal for network administrators, DevOps engineers, and anyone who regularly interacts with Linux-based
firewalls and needs an efficient way to handle NAT rules. With NAT Manager, you can easily add, delete, list, backup,
and restore NAT rules, all through a simple command-line interface.

## Features

- **Add NAT Rule:** Easily add a new NAT rule to IPTables.
- **Delete NAT Rule:** Remove an existing NAT rule.
- **List NAT Rules:** Display all current NAT rules.
- **Backup NAT Rules:** Backup your current NAT rules to a file.
- **Restore NAT Rules:** Restore NAT rules from a backup file.

## Usage

```bash
./natmanager.sh {add|delete|list|backup|restore} [parameters]
