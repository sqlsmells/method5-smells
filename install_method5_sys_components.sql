prompt Installing SYS components for Method5...


--#1: Generate password hashes.
--The password is never known.
--Only hashes are required for management, nobody will ever login as the Method5 user.
--These hashes are safer than passwords but should still be kept secret.
--Do not record the hashes, just retrieve them from the data dictionary when needed.

--Create user and grant it privileges.
declare
	--Password contains mixed case, number, and special characters.
	--This should meet most password complexity requirements.
	--It uses multiple sources for a truly random password.
	v_password_youll_never_know varchar2(30) :=
		replace(replace(dbms_random.string('p', 10), '"', null), '''', null)||
		rawtohex(dbms_crypto.randombytes(5))||
		substr(to_char(systimestamp, 'FF9'), 1, 6)||
		'#$*@';
	v_table_or_view_does_not_exist exception;
	pragma exception_init(v_table_or_view_does_not_exist, -942);
begin
	--Create user, grant it privileges.
	execute immediate 'create user method5 identified by "'||v_password_youll_never_know||'"';
	execute immediate 'grant dba to method5';
	--Need this for definer's rights procedure to grant custom tables to users:
	execute immediate 'grant grant any object privilege to method5';
	--Needed for some password security measures, such as removing the insecure DES password hashes.
	--(The column "PASSWORD" is not a password, it's a DES password hash that may need to be removed.)
	execute immediate 'grant select on sys.user$ to method5';
	execute immediate 'grant update (password) on sys.user$ to method5';

	--Direct grants necessary for packages.
	execute immediate 'grant create database link to method5';
	execute immediate 'grant select on dba_db_links to method5';
	execute immediate 'grant select on dba_profiles to method5';
	execute immediate 'grant select on dba_role_privs to method5';
	execute immediate 'grant select on dba_scheduler_job_run_details to method5';
	execute immediate 'grant select on dba_scheduler_jobs to method5';
	execute immediate 'grant select on dba_scheduler_running_jobs to method5';
	execute immediate 'grant select on dba_synonyms to method5';
	execute immediate 'grant select on dba_tables to method5';
	execute immediate 'grant select on dba_tab_columns to method5';
	execute immediate 'grant select on dba_users to method5';
	execute immediate 'grant select on sys.v_$parameter to method5';
	execute immediate 'grant select on sys.v_$sql to method5';
	execute immediate 'grant execute on sys.dbms_pipe to method5';
	execute immediate 'grant execute on sys.utl_mail to method5';
	execute immediate 'grant execute on sys.dbms_crypto to method5';
	execute immediate 'grant execute on sys.dbms_random to method5';

	begin
		execute immediate 'grant select on sysman.em_global_target_properties to method5';
		execute immediate 'grant select on sysman.mgmt$db_dbninstanceinfo to method5';
	exception when v_table_or_view_does_not_exist then null;
	end;

	--Create database link for retrieving the database link hash.
	execute immediate replace(
	q'[
		create or replace procedure method5.temp_proc_manage_db_link2 is
		begin
			execute immediate '
				create database link m5_install_db_link
				connect to method5
				identified by "$$PASSWORD$$"
				using '' (invalid name since we do not need to make a real connection) ''
			';
		end;
	]', '$$PASSWORD$$', v_password_youll_never_know);
	execute immediate 'begin method5.temp_proc_manage_db_link2; end;';
	execute immediate 'drop procedure method5.temp_proc_manage_db_link2';

	--Clear shared pool in case the password is stored anywhere.
	execute immediate 'alter system flush shared_pool';
end;
/


--#2: Audit all statements.
--This is sort-of a shared account and could benefit from extra protection. 
audit all statements by method5;


--#3a: Create SYS procedure to change database link password hashes.
--This procedure is very limited - it only works for one user, for specific link
--types, when called in a specific context.
begin
	sys.dbms_ddl.create_wrapped(ddl => q'<
create or replace procedure sys.m5_change_db_link_pw(
/*
Purpose: Change an M5_ database link password hash to the Method5 password hash.
	Since 11.2.0.4 the "IDENTIFIED BY VALUES" syntax does not work.
	So the links must be created with a phony password and SYS.LINK$ is updated.
Warning 1: This only works on new database links that haven't been cached.
Warning 2: This procedure modifies undocumented SYS table LINK$.
	It has only been tested for 11.2.0.4 and 12.1.0.2.
*/
	p_m5_username varchar2,
	p_dblink_username varchar2,
	p_dblink_name varchar2)
is
	v_owner varchar2(128);
	v_name varchar2(128);
	v_lineno number;
	v_caller_t varchar2(128);
begin
	--Error if the link name does not start with M5.
	if upper(trim(p_dblink_name)) not like 'M5%' then
		raise_application_error(-20000, 'This procedure only works for Method5 links.');
	end if;

	--TODO?  This would make it more difficult to ad hoc fix links.
	--TODO?  Use the Method5 authentication functions?
	--Error if the caller is not the Method5 package.
	--sys.owa_util.who_called_me(owner => v_owner, name => v_name, lineno => v_lineno, caller_t => v_caller_t);
	--
	--if v_name is null or v_name <> 'METHOD5' or v_caller_t is null or v_caller_t <> 'PACKAGE BODY' then
	--	raise_application_error(-20000, 'This procedure only works in one specific context.');
	--end if;

	--Change the link password hash to the real password hash.
	update sys.link$
	set passwordx =
	(
		--The real password hash.
		select passwordx
		from sys.link$
		join dba_users on link$.owner# = dba_users.user_id
		where dba_users.username = p_m5_username
			and name = 'M5_INSTALL_DB_LINK'
	)
	where name = upper(trim(p_dblink_name))
		and owner# = (select user_id from dba_users where username = upper(trim(p_dblink_username)));
end m5_change_db_link_pw;
>');
end;
/


--#4: Allow the package and DBAs to call the procedure.
grant execute on sys.m5_change_db_link_pw to method5, dba;


--#5: Create SYS procedure to return database hashes.
create or replace procedure sys.get_method5_hashes
--Purpose: Method5 administrators need access to the password hashes.
--But the table SYS.USER$ is hidden in 12c, we only want to expose this one hash.
--
--TODO 1: http://www.red-database-security.com/wp/best_of_oracle_security_2015.pdf
--	The 12c hash is incredibly insecure.  Is it safe to remove the "H:" hash?
--TODO 2: Is there a way to derive the 10g hash from the 12c H: hash?
--	Without that, 12c local does not support remote 10g or 11g with case insensitive passwords.
(
	p_12c_hash in out varchar2,
	p_11g_hash_without_des in out varchar2,
	p_11g_hash_with_des in out varchar2
) is
begin
	--10 and 11g.
	$if dbms_db_version.ver_le_11_2 $then
		select
			spare4,
			spare4 hash_without_des,
			spare4||';'||password hash_with_des
		into p_12c_hash, p_11g_hash_without_des, p_11g_hash_with_des
		from sys.user$
		where name = 'METHOD5';
	--12c.
	$else
		select
			spare4,
			regexp_substr(spare4, 'S:.{60}')
		into p_12c_hash, p_11g_hash_without_des
		from sys.user$
		where name = 'METHOD5';
	$end
end;
/


--#6: Allow the package and DBAs to call the procedure.
grant execute on sys.get_method5_hashes to method5, dba;


prompt Done.
