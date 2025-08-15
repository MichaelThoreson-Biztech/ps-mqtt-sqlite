# ps-mqtt-sqlite
 stores mqtt messages to a SQLite server

## Usage
### Collecting tags
- enter the MQTT topics that you need to record in topics.txt
- ensure that the variable $mqttBroker is set in the script body of PS_mqtt_to_sqlite.ps1.
- run the script "PS_mqtt_to_sqlite.ps1". 
    - This script will place the database in the path specified by the "SQLITEPATH" environment variable. The file will be named "db.sqlite3".
    - In order to set this to your current directory, run it like this:
    
    ```$env:SQLITEPATH = "./"; .\PS_mqtt_to_sqlite.ps1```
- The script will record all mqtt messages that are declared in Jobs.txt, provided that the topic is in the format "decoded/\<machine\>/\<topic\>", and that the messages are JSON data which contain a "timestamp" attribute paired with at least one other non-metrics attribute.
### Querying tags
- TODO embed image of db schema

```
--Example query: This shows attribute "seq", from tag "log_count", on machine "debarker"
--You can do similar queries with any given set of attributes, for any Tag, belonging to any Machine.

SELECT 
    Msg.ID AS 'Msg_ID',
    Msg.timestamp As 'Msg_time',
    MAX(CASE WHEN Attrib.key = 'seq' THEN Attrib.val END) AS 'seq' -- repeat this for each desired attribute within the message
FROM Msg 
LEFT JOIN Attrib ON Attrib.Msg_ID = Msg.ID 
LEFT JOIN Machine_Tag_Msg on Machine_tag_Msg.Msg_ID = Msg.ID 
Where Machine_tag_msg.Machine_name = 'debarker' 
and Machine_tag_msg.Tag_name = 'log_count'
GROUP BY Msg.ID;
```

 

<!-- Purpose: Logs MQTT data or   -->
<!-- INSTALL_COMMAND: TODO -->
<!-- RUN_COMMAND: $env:SQLITEPATH = "<INSERT PATH TO DB FILE>"; .\PS_mqtt_to_sqlite.ps1 -->