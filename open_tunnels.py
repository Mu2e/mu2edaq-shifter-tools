#!/usr/bin/env python3
import os
import json
import subprocess
import argparse
from PyQt5.QtWidgets import QApplication, QMessageBox
from PyQt5.QtCore import Qt
import sys

# Calculate base port using user ID
userid = os.getuid()
baseport = userid + 973

def show_tunnels_gui(filename='.open_tunnel_pids'):
    """
    Display a Qt-based message window showing active SSH tunnels.
    """
    #try:
    #except ImportError:
    #    print("PyQt5 is not installed. Install with: pip install PyQt5")
    #    return
    
    app = QApplication(sys.argv)
    msg_box = QMessageBox()
    msg_box.setWindowTitle("Active SSH Tunnels")
    
    try:
        with open(filename, 'r') as pid_file:
            tunnel_info = []
            for line in pid_file:
                pid, hostname, username, port = [item.strip() for item in line.strip().split(',')]
                # Check if process is active
                result = subprocess.run(['ps', '-p', pid], capture_output=True, text=True)
                status = "ACTIVE" if result.returncode == 0 else "NOT ACTIVE"
                tunnel_info.append(f"PID: {pid}\nHost: {hostname}\nUser: {username}\nLocal Port: {port}\nStatus: {status}\n")
            
            if tunnel_info:
                msg_box.setText("Active SSH Tunnels:\n\n" + "\n".join(tunnel_info))
            else:
                msg_box.setText("No active tunnels found.")
        
    except FileNotFoundError:
        msg_box.setText("No PID file found. No active tunnels.")
    
    msg_box.setStandardButtons(QMessageBox.Ok)

    msg_box.exec_()

def read_tunnels(json_file):
    """
    Read host and port numbers from a JSON file.
    
    Args:
        json_file: Path to the JSON file
        
    Returns:
        List of dictionaries containing host and port information
    """
    with open(json_file, 'r') as f:
        tunnels = json.load(f)
    return tunnels

def kill_tunnels(filename='.open_tunnel_pids'):
        """
        Kill all SSH tunnel processes listed in the PID file.
        """
        try:
            with open(filename, 'r') as pid_file:
                for line in pid_file:
                    # The PID is the first element before the comma
                    pid = line.strip().split(',')[0]
                    if pid:
                        try:
                            subprocess.run(['kill', pid], check=True)
                            print(f"Killed process {pid}")
                        except subprocess.CalledProcessError:
                            print(f"Failed to kill process {pid} (may not exist)")
        except FileNotFoundError:
            print("No PID file found. No tunnels to kill.") 

def list_tunnels(filename='.open_tunnel_pids'):
    """
    List all active SSH tunnels from the PID file.
    """
    try:
        with open(filename, 'r') as pid_file:
            for line in pid_file:
#                print(line.strip())
#               The format is: PID, hostname, username, port
#              We will print a more user-friendly message
#             Example line: 12345, mu2edaq.fnal.gov, user, 10023
                pid, hostname, username, port = [item.strip() for item in line.strip().split(',')]
                # Now try to find this PID in the process list
                result = subprocess.run(['ps', '-p', pid], capture_output=True, text=True)
                if result.returncode == 0:  # Process exists
                    active ="\033[92mACTIVE\033[0m"
                else:
                    active = "\033[91mNOT ACTIVE\033[0m"
                print(f"Tunnel PID: {pid}, Host: {hostname}, User: {username}, Local Port: {port}, Status: {active}")               
    except FileNotFoundError:
        print("No PID file found. No active tunnels.")

def open_tunnels(tunnels):
    """
    Open SSH tunnels based on the provided tunnel configurations.
    
    Args:
        tunnels: List of dictionaries containing host and port information
    """
    with open('.open_tunnel_pids', 'w') as pid_file:
        # Clear the pid file
        pid_file.truncate(0)

        for tunnel in tunnels:
            print(f"Host: {tunnel['hostname']}, Port: {tunnel['port']}")
            theport = baseport + tunnel['port']
            theusername = tunnel['username']
            thehostname = tunnel['hostname']
            process = subprocess.Popen(['ssh', '-N', '-L', f"{theport}:localhost:{theport}", f"{theusername}@{thehostname}"])
            pid = process.pid
            pid_file.write(f"{pid}, {thehostname}, {theusername}, {theport}\n")
            print("Tunnels are being established...")
            print(f"Access the service at localhost:{theport}")
    print("All tunnels have been initiated.")

if __name__ == "__main__":
    # Example usage
    tunnels = read_tunnels('tunnels.json')

    parser = argparse.ArgumentParser(description='Manage Mu2e SSH tunnels')
    parser.add_argument('action', choices=['open', 'kill','list'], help='Action to perform: open, kill, or list tunnels')
    parser.add_argument('--pid-file', default='.open_tunnel_pids', help='Path to PID file (default: .open_tunnel_pids)')
    parser.add_argument('--gui', action='store_true', help='Show tunnels in GUI window (use with list action)')
    args = parser.parse_args()
    
    pid_file = open(args.pid_file, 'a+')
    if args.action == 'kill':
        kill_tunnels()
        pid_file.truncate(0)
        exit(0)

    if args.action == 'open':
        # Clear the pid file before opening new tunnels
        pid_file.truncate(0)

        # Open the tunnels
        open_tunnels(tunnels)
        exit(0)

    if args.action == 'list':  
        list_tunnels()
        if args.gui:
            show_tunnels_gui(args.pid_file)
        exit(0)

    

 
