# Ensure the modules are installed and import it
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Install-Module -Name PSSQLite -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name PSMQTT)) {
    Install-Module -Name PSMQTT -Scope CurrentUser -Force
}
Import-Module PSSQLite
#Import-Module PSMQTT

# Function to handle incoming MQTT messages
function OnMessageReceived {
    param (
        [string]$topic,
        [string]$message,
        [string]$dbPath
    )

    # Insert data into SQLite database
    $insertQuery = "INSERT INTO SensorData (Topic, Message) VALUES ('$topic', '$message');"
    try {
        Invoke-SqliteQuery -DataSource $dbPath -Query $insertQuery
    } catch {
        Write-Host "Failed to insert data into database: $_" -ForegroundColor Red
    }
}

# Function to connect to MQTT broker and subscribe to a single topic
function Connect-MQTTBrokerAndSubscribe {
    param (
        [string]$broker,
        [string]$topic,
        [string]$dbPath
    )

    $session = Connect-MQTTBroker -HostName $broker
    Watch-MQTTTopic -Session $session -Topic $topic | ForEach-Object {
        $messageParts = $_ -split ";"
        $receivedTopic = $messageParts[0]
        $receivedMessage = $messageParts[1]
        OnMessageReceived -topic $receivedTopic -message $receivedMessage -dbPath $dbPath
    }
}

# Function to initialize the SQLite database
function Initialize-Database {
    param (
        [string]$dbPath
    )

    if (-Not (Test-Path $dbPath)) {
        $createTableQuery = @"
        CREATE TABLE IF NOT EXISTS SensorData (
            Id INTEGER PRIMARY KEY AUTOINCREMENT,
            Topic TEXT NOT NULL,
            Message TEXT NOT NULL,
            Timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
"@
        try {
            Invoke-SqliteQuery -DataSource $dbPath -Query $createTableQuery
        } catch {
            Write-Host "Failed to create database and table: $_" -ForegroundColor Red
        }
    }
}

# Function to start a job for a topic
function Start-TopicJob {
    param (
        [string]$broker,
        [string]$topic,
        [string]$dbPath
    )

    Start-Job -ScriptBlock {
        param ($broker, $topic, $dbPath)

        function OnMessageReceived {
            param (
                [string]$topic,
                [string]$message,
                [string]$dbPath
            )

            $insertQuery = "INSERT INTO SensorData (Topic, Message) VALUES ('$topic', '$message');"
            try {
                Invoke-SqliteQuery -DataSource $dbPath -Query $insertQuery
            } catch {
                Write-Host "Failed to insert data into database: $_" -ForegroundColor Red
            }
        }

        function Connect-MQTTBrokerAndSubscribe {
            param (
                [string]$broker,
                [string]$topic,
                [string]$dbPath
            )

            $session = Connect-MQTTBroker -HostName $broker
            Watch-MQTTTopic -Session $session -Topic $topic | ForEach-Object {
                $messageParts = $_ -split ";"
                $receivedTopic = $messageParts[0]
                $receivedMessage = $messageParts[1]
                OnMessageReceived -topic $receivedTopic -message $receivedMessage -dbPath $dbPath
            }
        }
        Import-Module PSMQTT
        Import-Module PSSQLite
        try {
            Connect-MQTTBrokerAndSubscribe -broker $broker -topic $topic -dbPath $dbPath
        } catch {
            Write-Host "Error in job for topic ${topic}: $_" -ForegroundColor Red
        }
    } -ArgumentList $broker, $topic, $dbPath
}

# Function to clean up jobs
function Cleanup-Jobs {
    param (
        [array]$jobs
    )

    foreach ($job in $jobs) {
        if ($job.State -ne 'Completed') {
            Stop-Job -Job $job
        }
        Remove-Job -Job $job
    }
}

# Main script
$mqttBroker = "192.168.203.127"
$topics = @("Switch1", "Flow1", "Switch2", "Capacity1")
$dbDirectory = [System.Environment]::GetEnvironmentVariable('SQLITEPATH')
if (-not $dbDirectory) {
    $dbDirectory = "C:\Windows\Temp\mqtt"
    if (-not (Test-Path $dbDirectory)) {
        New-Item -Path $dbDirectory -ItemType Directory | Out-Null
    }
}
$dbPath = Join-Path -Path $dbDirectory -ChildPath "db.sqlite3"

# Initialize database
Initialize-Database -dbPath $dbPath

# Start jobs for each topic
$jobs = @()
foreach ($topic in $topics) {
    $jobs += Start-TopicJob -broker $mqttBroker -topic $topic -dbPath $dbPath
}

# Monitor jobs and handle script termination
try {
    while ($true) {
        foreach ($job in $jobs) {
            if ($job.State -eq 'Completed') {
                try {
                    Receive-Job -Job $job
                } catch {
                    Write-Host "Error in job for topic $($job.ChildJobs[0].Command): $_" -ForegroundColor Red
                } finally {
                    Remove-Job -Job $job
                    $jobs = $jobs | Where-Object { $_ -ne $job }
                }
            }
        }
        Start-Sleep -Seconds 1
    }
} finally {
    Cleanup-Jobs -jobs $jobs
}