function start_olympus_tcp_server(port,maxMessages,mode)
% Emulate <-> MATLAB thermal plant <-> Ubuntu OpenFOAM floor bridge.
% CFD mode advances actual CFD. Failures never silently fall back to ROM.
if nargin<1, port=55001; end
if nargin<2, maxMessages=inf; end
if nargin<3, mode='cfd'; end
assert(any(strcmp(mode,{'cfd','rom'})),'Mode must be cfd or rom.');
identity='ProjectOlympus.MATLAB';
serverSocket=javaObject('java.net.ServerSocket');
serverSocket.setReuseAddress(true);
try
    address=javaMethod('getByName','java.net.InetAddress','127.0.0.1');
    serverSocket.bind(javaObject('java.net.InetSocketAddress',address,port));
catch err
    serverSocket.close();
    if contains(err.message,'Address already in use','IgnoreCase',true)
        try
            existing=olympus_exchange_json(port,struct('Command','ping'),2000);
        catch
            error('Olympus:PortOccupied','Port %d is occupied by an unverified service. No process was stopped.',port);
        end
        if isfield(existing,'Service') && strcmp(existing.Service,identity)
            fprintf('Olympus already on %d, mode=%s. Reusing existing instance.\n',port,existing.Mode);
            return
        end
        error('Olympus:PortOccupied','Port %d belongs to another service.',port);
    end
    rethrow(err)
end
cleanup=onCleanup(@()serverSocket.close());
out=fullfile(fileparts(mfilename('fullpath')),'output');
if ~isfolder(out), mkdir(out); end
fprintf('Olympus MATLAB on 127.0.0.1:%d; mode=%s\n',port,mode);
fid=fopen(fullfile(out,'tcp_ready.txt'),'w'); fprintf(fid,'%d %s\n',port,mode); fclose(fid);
count=0; lastRequest=''; lastResponse=[];
while count<maxMessages
    socket=serverSocket.accept();
    socketCleanup=onCleanup(@()socket.close());
    socket.setSoTimeout(5000);
    reader=javaObject('java.io.BufferedReader',javaObject('java.io.InputStreamReader',socket.getInputStream(),'UTF-8'));
    writer=javaObject('java.io.PrintWriter',javaObject('java.io.OutputStreamWriter',socket.getOutputStream(),'UTF-8'),true);
    try
        line=reader.readLine();
        if isempty(line), clear socketCleanup; continue; end
        request=jsondecode(char(line));
        if isfield(request,'Command') && strcmp(request.Command,'ping')
            response=struct('Service',identity,'DataValid',true,'Mode',mode,...
                'SupportsFourRacks',true,'ProjectRoot',...
                fileparts(fileparts(fileparts(mfilename('fullpath')))),...
                'CalibrationVersion','V9_20260928');
        elseif strcmp(char(line),lastRequest)
            response=lastResponse;
        else
            validateRequest(request);
            if strcmp(mode,'cfd')
                floorResult=olympus_exchange_json(55000,request);
                assert(floorResult.DataValid,'Ubuntu CFD failed: %s',jsonencode(floorResult));
                assert(floorResult.OutputSequence==request.InputSequence,'Ubuntu sequence mismatch.');
                request.MeasuredCRACFlow_m3_s=floorResult.CRAC_flow_m3_s;
                request.MeasuredSupplyTemp_C=floorResult.Floor_supply_temp_C;
            end
            if isfield(request,'RackLoads')
                response=olympus_four_rack_step(request);
            else
                response=olympus_live_step(request);
            end
            response.Service=identity; response.Mode=mode;
            response.CPUModel='MATLAB reduced thermal network; provisional CPU R/C';
            if strcmp(mode,'cfd')
                response.CFD_time_s=floorResult.CFD_time_s;
                response.Floor_supply_temp_C=floorResult.Floor_supply_temp_C;
                response.SolverWallTime_s=floorResult.SolverWallTime_s;
                response.MassMismatch_fraction=floorResult.MassMismatch_fraction;
                response.FloorZones=reduceFloorMap(floorResult);
                response.FloorMapCFDTime_s=floorResult.FloorMapCFDTime_s;
                response.FloorMapSource=[floorResult.FloorMapSource '; MATLAB arithmetic mean of 6 probes per zone'];
                response.FloorMapCoordinates='OpenFOAM: x length, y width, z height; Emulate: X=x, Y=z, Z=y';
                telemetry=response; telemetry.Command='telemetry';
                ack=olympus_exchange_json(55000,telemetry,5000);
                assert(ack.DataValid && ack.OutputSequence==response.OutputSequence,'Ubuntu telemetry acknowledgement failed.');
                response.UbuntuReturnAcknowledged=true;
            else
                response.UbuntuReturnAcknowledged=false;
            end
            lastRequest=char(line); lastResponse=response; count=count+1;
            fid=fopen(fullfile(out,'live_latest.json'),'w'); fprintf(fid,'%s\n',jsonencode(response)); fclose(fid);
            fid=fopen(fullfile(out,'live_transactions.jsonl'),'a');
            fprintf(fid,'%s\n',jsonencode(struct('receivedUTC',char(datetime('now','TimeZone','UTC')),'request',request,'response',response))); fclose(fid);
        end
    catch err
        response=struct('Service',identity,'schemaVersion',1,'DataValid',false,'FaultCode',1,'FaultMessage',err.message);
    end
    try, writer.println(jsonencode(response)); catch, end
    clear socketCleanup
end
end

function zones=reduceFloorMap(floorResult)
% 72 solved-field probes become 12 lightweight heat/flow display zones.
% Speed is the magnitude of the averaged velocity, not a volume flow rate.
p=floorResult.FloorSamples;
assert(isnumeric(p) && isequal(size(p),[72 7]) && all(isfinite(p),'all'),...
    'Invalid CFD floor-map sample array.');
assert(abs(floorResult.FloorMapCFDTime_s-floorResult.CFD_time_s)<1e-6,...
    'Stale CFD floor-map time.');
template=struct('x_m',0,'y_m',0,'z_m',0,'Ux_m_s',0,'Uy_m_s',0,...
    'Uz_m_s',0,'Temperature_C',0,'Speed_m_s',0);
zones=repmat(template,12,1); n=0;
for row=0:1
    for col=0:5
        select=p(:,1)>=col & p(:,1)<col+1 & p(:,2)>=-.9+row*.9 & p(:,2)<row*.9;
        assert(nnz(select)==6,'Missing probes in CFD floor-map zone.');
        v=mean(p(select,:),1); n=n+1;
        zones(n)=struct('x_m',v(1),'y_m',v(2),'z_m',v(3),...
            'Ux_m_s',v(4),'Uy_m_s',v(5),'Uz_m_s',v(6),...
            'Temperature_C',v(7),'Speed_m_s',norm(v(4:6)));
    end
end
end

function validateRequest(u)
fields={'dt_s','InputSequence','CPU1_W_per_server','CPU2_W_per_server',...
    'ServerFanPWM_cmd_pct','CRAC_PWM_cmd_pct','CRAC_capacity_fraction','CRAC_supply_temp_C'};
lo=[.05 0 0 0 0 0 0 0]; hi=[10 2147483647 205 205 100 100 1 50];
for k=1:numel(fields)
    assert(isfield(u,fields{k}),'Missing field %s.',fields{k});
    v=u.(fields{k});
    assert(isnumeric(v) && isscalar(v) && isfinite(v) && v>=lo(k) && v<=hi(k),'Invalid %s.',fields{k});
end
assert(u.InputSequence==fix(u.InputSequence),'InputSequence must be an integer.');
end
