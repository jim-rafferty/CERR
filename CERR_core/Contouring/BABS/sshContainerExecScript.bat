set ssh_key=%1
set ssh_uname_server_name=%2
set client_session_dir=%3
set server_session_dir=%4
set session_name=%5
set container_path=%6
set batch_size=%7
set algorithm=%8

@echo %algorithm%
@echo %batch_size%

@echo Copying session dir from client to server...
@echo %client_session_dir%
@echo %server_session_dir%
pscp -noagent -r %client_session_dir% %ssh_uname_server_name%:%server_session_dir%

@echo Setting bind path for container
set bindingPath=%server_session_dir%/%session_name%:/scratch

@echo Executing container 
plink -noagent -ssh %ssh_uname_server_name% (source  /admin/lsf/mph/conf/profile.lsf; bsub -R rusage[mem=30] -q research -n 1  -W 1:00  -gpu "num=1:gmem=4GB:mode=exclusive_process:mps=no:j_exclusive=yes" -Is singularity run --app %algorithm% --nv --bind  %bindingPath% %container_path% %batch_size%)

@echo Copying result back to Client from Server
pscp -noagent -r %ssh_uname_server_name%:%server_session_dir%/%session_name%/outputH5 %client_session_dir%

@echo DONE

