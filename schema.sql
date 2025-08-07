PRAGMA foreign_keys = ON;
create table Machine(
    ID   integer primary key autoincrement,
    Name String unique not null
);
create table Tag(
    ID         integer primary key autoincrement,
    machine_ID integer not null,
    name       string not null,
    UNIQUE(ID,name) on conflict ignore,
    foreign key(Machine_ID) references Machine(ID)
);
create table Msg(
    ID         integer primary key autoincrement,
    tag_ID     integer not null,
    timestamp DATETIME Default CURRENT_TIMESTAMP,
    foreign key(tag_ID) references Tag(ID)
);
create table Attrib(
    ID         integer primary key autoincrement,
    Msg_ID references Msg (ID),
    parent     references Attrib (ID),
    key string not null,
    val string default attr_list not null,
    UNIQUE(parent,msg_ID,key) on conflict ignore
);
CREATE VIEW Machine_Tag_Msg AS 
SELECT 
    Machine.Name "Machine_Name",
    Machine.ID "Machine_ID",
    Tag.Name "Tag_Name",
    Tag.ID "Tag_ID",
    Msg.ID "Msg_ID"
FROM Msg 
JOIN Tag ON Msg.tag_ID = Tag.ID JOIN Machine ON Machine.ID = Tag.machine_ID;


--Example query: This shows attribute "seq", from tag "log_count", on machine "debarker"
--You can do similar queries with any given set of attributes, for any Tag, belonging to any Machine.

/*SELECT 
    Msg.ID AS "Msg_ID",
    Msg.timestamp As "Msg_time",
    MAX(CASE WHEN Attrib.key = 'seq' THEN Attrib.val END) AS "seq"
FROM Msg 
LEFT JOIN Attrib ON Attrib.Msg_ID = Msg.ID 
LEFT JOIN Machine_Tag_Msg on Machine_tag_Msg.Msg_ID = Msg.ID 
Where Machine_tag_msg.Machine_name = "debarker" 
and Machine_tag_msg.Tag_name = "log_count"
GROUP BY Msg.ID;*/