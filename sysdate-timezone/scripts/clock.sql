-- What this session sees. OFFSET = SYSDATE minus UTC, in hours; CHICAGO = Chicago's offset right now (-5 or -6)
set heading off feedback off pages 0 lines 200
select 'SYSDATE=' || to_char(sysdate, 'YYYY-MM-DD HH24:MI')
    || ' SYSTIMESTAMP=' || to_char(systimestamp, 'HH24:MI TZR')
    || ' CURRENT_DATE=' || to_char(current_date, 'HH24:MI')
    || ' SESSIONTIMEZONE=' || sessiontimezone
    || ' DBTIMEZONE=' || dbtimezone
  from dual;
select 'OFFSET=' || round((sysdate - cast(sys_extract_utc(systimestamp) as date)) * 24) from dual;
select 'CURRENT_DATE_OFFSET=' || round((current_date - cast(sys_extract_utc(systimestamp) as date)) * 24) from dual;
select 'DBTIMEZONE=' || dbtimezone from dual;
select 'CHICAGO=' || extract(timezone_hour from systimestamp at time zone 'America/Chicago') from dual;
exit
