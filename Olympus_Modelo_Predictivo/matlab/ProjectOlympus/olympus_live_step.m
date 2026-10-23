function y = olympus_live_step(u)
%OLYMPUS_LIVE_STEP Conservative reduced plant, not a live Navier-Stokes solve.
% CPU/sink R,C and the default 0.30 m3 rack air inventory are provisional.
% The measured floor tracer delay describes material transport, not flow.
% Imposed-flow CFD supplies a quasi-steady flow gain; motor inertia and
% variable-flow supply-temperature transport are not identified here.
persistent rackStates crac
if ~isfield(u,'RackId'), u.RackId=1; end
assert(isscalar(u.RackId) && isfinite(u.RackId) && u.RackId==fix(u.RackId) && u.RackId>=1 && u.RackId<=4,'Invalid RackId');
% Component experiments and the four-rack room must not share thermal history.
% Otherwise running a single-rack test first advances only room rack 1.
if isempty(rackStates),rackStates=cell(1,8);end
stateIndex=u.RackId+4*isfield(u,'RackLoads');
s=rackStates{stateIndex};
if isempty(crac)
    d=import_crac_cfd(); crac=d.model;
end
if ~isfield(u,'dt_s'), u.dt_s=1; end
if ~isfield(u,'Reset'), u.Reset=false; end
if ~isfield(u,'Rack_air_volume_m3'), u.Rack_air_volume_m3=.30; end
if ~isfield(u,'OtherIT_W_per_server'), u.OtherIT_W_per_server=0; end
names={'dt_s','InputSequence','CPU1_W_per_server','CPU2_W_per_server',...
    'ServerFanPWM_cmd_pct','CRAC_PWM_cmd_pct','CRAC_capacity_fraction',...
    'CRAC_supply_temp_C','Rack_air_volume_m3','OtherIT_W_per_server'};
for k=1:numel(names)
    name=names{k};
    assert(isfield(u,name) && isnumeric(u.(name)) && isreal(u.(name)) && ...
        isscalar(u.(name)) && isfinite(u.(name)), 'Olympus:InvalidInput',...
        'Input %s must be a finite real scalar.',name);
end
assert(isscalar(u.Reset) && (islogical(u.Reset) || isnumeric(u.Reset)) && ...
    any(u.Reset==[0 1]),'Olympus:InvalidInput','Reset must be true or false.');
assert(u.dt_s>0 && u.dt_s<=10,'Olympus:InvalidInput','dt_s must be in (0,10].');
assert(u.InputSequence>=0 && fix(u.InputSequence)==u.InputSequence,...
    'Olympus:InvalidInput','InputSequence must be a nonnegative integer.');
assert(min([u.CPU1_W_per_server u.CPU2_W_per_server])>=0,...
    'Olympus:InvalidInput','CPU power cannot be negative.');
assert(u.OtherIT_W_per_server>=0,'Olympus:InvalidInput','Other IT heat cannot be negative.');
assert(min([u.ServerFanPWM_cmd_pct u.CRAC_PWM_cmd_pct])>=0 && ...
    max([u.ServerFanPWM_cmd_pct u.CRAC_PWM_cmd_pct])<=100,...
    'Olympus:InvalidInput','Fan commands must be in [0,100].');
assert(u.CRAC_capacity_fraction>=0 && u.CRAC_capacity_fraction<=1,...
    'Olympus:InvalidInput','CRAC_capacity_fraction must be in [0,1].');
assert(u.Rack_air_volume_m3>0,'Olympus:InvalidInput','Rack air volume must be positive.');
optional={'MeasuredCRACFlow_m3_s','MeasuredSupplyTemp_C'};
for k=1:numel(optional)
    name=optional{k};
    if isfield(u,name)
        v=u.(name);
        assert(isnumeric(v) && isreal(v) && isscalar(v) && isfinite(v),...
            'Olympus:InvalidInput','Input %s must be a finite real scalar.',name);
    end
end
if isfield(u,'MeasuredCRACFlow_m3_s')
    assert(u.MeasuredCRACFlow_m3_s>=0,'Olympus:InvalidInput','Measured flow cannot be negative.');
end
Ts=double(u.CRAC_supply_temp_C);
if isfield(u,'MeasuredSupplyTemp_C'), Ts=double(u.MeasuredSupplyTemp_C); end
if isempty(s) || u.Reset
    s.time=0; s.x=repmat(Ts,6,1);
    s.airVolume=u.Rack_air_volume_m3;
end
assert(s.airVolume==u.Rack_air_volume_m3,'Olympus:InvalidInput',...
    'Reset is required when changing rack air volume.');

dt=double(u.dt_s); N=20; rho=1.204; cp=1004.4;
server=server_cfd_coefficients(double(u.ServerFanPWM_cmd_pct));
qCrac=crac.flow_response.gain_m3_s_per_percent_PWM*...
    u.CRAC_PWM_cmd_pct*u.CRAC_capacity_fraction;
if isfield(u,'MeasuredCRACFlow_m3_s'), qCrac=double(u.MeasuredCRACFlow_m3_s); end
qServer=server.TotalFlow_m3s; qRack=N*qServer;
qFresh=min(qCrac,qRack);
recirc=0; if qRack>0, recirc=1-qFresh/qRack; end
P=double([u.CPU1_W_per_server u.CPU2_W_per_server]);
Rch=server.CPUToSinkResistance_K_W; Rpipe=server.HeatPipeResistance_K_W;
Ccpu=20; Chs=158.546; Cremote=620; Cair=rho*cp*s.airVolume;
Gfresh=rho*cp*qFresh;

% States: two CPU dies, two local sinks, one shared remote sink, rack air,
% rejected heat, and a constant. CFD supplies flow; solid R/C remains assumed.
A=zeros(8); gch=1/Rch; gpipe=1/Rpipe;
for j=1:2
    glocal=server.LocalConductance_W_K(j);
    A(j,j)=-gch/Ccpu; A(j,j+2)=gch/Ccpu; A(j,8)=P(j)/Ccpu;
    A(j+2,j)=gch/Chs; A(j+2,j+2)=-(gch+gpipe+glocal)/Chs;
    A(j+2,5)=gpipe/Chs; A(j+2,6)=glocal/Chs;
    A(5,j+2)=A(5,j+2)+gpipe/Cremote;
    A(5,5)=A(5,5)-gpipe/Cremote;
    A(6,j+2)=N*glocal/Cair; A(6,6)=A(6,6)-N*glocal/Cair;
end
gremote=server.RemoteConductance_W_K;
A(5,5)=A(5,5)-gremote/Cremote; A(5,6)=gremote/Cremote;
A(6,5)=N*gremote/Cair; A(6,6)=A(6,6)-N*gremote/Cair;
A(6,6)=A(6,6)-Gfresh/Cair; A(6,8)=(Gfresh*Ts+N*u.OtherIT_W_per_server)/Cair;
A(7,6)=Gfresh; A(7,8)=-Gfresh*Ts;
weights=[N*Ccpu N*Ccpu N*Chs N*Chs N*Cremote Cair];
old=s.x; next=expm(A*dt)*[old;0;1]; s.x=next(1:6); s.time=s.time+dt;
stored_J=weights*(s.x-old); rejected_J=next(7); input_J=N*(sum(P)+u.OtherIT_W_per_server)*dt;
Tout=s.x(6); Tin=(1-recirc)*Ts+recirc*Tout;
y=struct('schemaVersion',1,'OutputSequence',u.InputSequence,'time_s',s.time,...
    'CRAC_flow_m3_s',qCrac,'Rack_demand_flow_m3_s',qRack,...
    'Recirculation_fraction',recirc,'Rack_inlet_C',Tin,'Rack_outlet_C',Tout,...
    'CPU1_die_est_C',s.x(1),'CPU2_die_est_C',s.x(2),...
    'CPU1_heatsink_C',s.x(3),'CPU2_heatsink_C',s.x(4),...
    'Remote_heatsink_C',s.x(5),...
    'CPU_input_W',N*sum(P),'OtherIT_input_W',N*u.OtherIT_W_per_server,...
    'IT_input_W',N*(sum(P)+u.OtherIT_W_per_server),...
    'Heat_input_J',input_J,'Stored_energy_change_J',stored_J,...
    'Heat_rejected_J',rejected_J,'Energy_balance_residual_J',input_J-stored_J-rejected_J,...
    'ThermalAlarm',max(s.x(1:2))>=85 || recirc>.25 || (qRack==0 && (sum(P)+u.OtherIT_W_per_server)>0),...
    'DataValid',all(isfinite(s.x)),...
    'Heartbeat',floor(s.time),'ModelKind','conservative_thermal_ROM',...
    'CalibrationStatus','V9_CFD_flow_interpolated_thermal_RC_provisional',...
    'WithinCFDFlowDomain',server.CalibrationDomain);
rackStates{stateIndex}=s;
end
