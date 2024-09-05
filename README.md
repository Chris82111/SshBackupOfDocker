# SshBackupOfDocker

The repo creates a backup of folders from a remote server and downloads the archive. The main task is to create a backup of a Docker container. An encrypted private key file is used for the login. All data and settings are saved externally in a json file so that the script can remain unchanged while the configuration file is changed.

The script has a `-h` and `--help` switch. These switches provide you with all the necessary information about switches and return values.

## Steps in the script

```mermaid
  sequenceDiagram
    actor S as sshBackupOfDocker Server
    participant  P as Peer Server
    S->>S:   (1) Test requirements and SSH settings
    S->>+P:  Execute script
    P->>P:   (2) Stop the Docker container <br/> (3) Wait for the container to shut down <br/> (4) Create packed file of the selected folders <br/> (5) Start the Docker container
    P-->>-S: 
    S->>+P: 
    P-->>-S: (6) Download packed file
    S->>+P: 
    P-->>-S: (7) Get SHA of the packed file on the server
    S->>S:   (8) Retrieve SHA of the packed file locally <br/> (9) Add postfix `valid` or `damaged`

```
