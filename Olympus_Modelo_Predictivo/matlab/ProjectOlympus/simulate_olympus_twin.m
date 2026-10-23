function out = simulate_olympus_twin(in,crac)
%SIMULATE_OLYMPUS_TWIN Drive the same thermal plant used by the live bridge.
% CRAC flow transport follows the identified floor model. The server flow
% comes from the V9 CFD sweep; solid thermal R/C remains assumed.
t=in.time_s; n=height(in); dt=median(diff(t));
assert(all(abs(diff(t)-dt)<1e-6),'Input time step must be uniform.');
L=crac.FOPDT_tracer_model.dead_time_L_s;
tau=crac.FOPDT_tracer_model.time_constant_tau_s;
gain=crac.flow_response.gain_m3_s_per_percent_PWM;

qCrac=zeros(n,1);qRack=zeros(n,1);recirc=zeros(n,1);
Tin=zeros(n,1);Tout=zeros(n,1);Tcpu1=zeros(n,1);Tcpu2=zeros(n,1);
Ths1=zeros(n,1);Ths2=zeros(n,1);alarm=zeros(n,1);dataValid=true(n,1);
qCrac(1)=gain*in.CRAC_PWM_cmd_pct(1)*in.CRAC_capacity_fraction(1);
first=server_cfd_coefficients(in.ServerFanPWM_cmd_pct(1));
qRack(1)=20*first.TotalFlow_m3s;
Tin(1)=in.CRAC_supply_temp_C(1);Tout(1)=Tin(1);
Tcpu1(1)=Tin(1);Tcpu2(1)=Tin(1);Ths1(1)=Tin(1);Ths2(1)=Tin(1);

u=struct('RackId',1,'dt_s',dt,'Reset',true,'Rack_air_volume_m3',.30);
for k=2:n
    delayed=max(1,min(k,floor((t(k)-L-t(1))/dt)+1));
    target=gain*in.CRAC_PWM_cmd_pct(delayed)*in.CRAC_capacity_fraction(delayed);
    qCrac(k)=qCrac(k-1)+(1-exp(-dt/tau))*(target-qCrac(k-1));
    u.Reset=(k==2);u.InputSequence=k;
    u.CPU1_W_per_server=in.CPU1_W_per_server(k);
    u.CPU2_W_per_server=in.CPU2_W_per_server(k);
    u.ServerFanPWM_cmd_pct=in.ServerFanPWM_cmd_pct(k);
    u.CRAC_PWM_cmd_pct=in.CRAC_PWM_cmd_pct(k);
    u.CRAC_capacity_fraction=in.CRAC_capacity_fraction(k);
    u.CRAC_supply_temp_C=in.CRAC_supply_temp_C(k);
    u.MeasuredCRACFlow_m3_s=qCrac(k);
    y=olympus_live_step(u);
    qRack(k)=y.Rack_demand_flow_m3_s;
    recirc(k)=y.Recirculation_fraction;
    Tin(k)=y.Rack_inlet_C;Tout(k)=y.Rack_outlet_C;
    Tcpu1(k)=y.CPU1_die_est_C;Tcpu2(k)=y.CPU2_die_est_C;
    Ths1(k)=y.CPU1_heatsink_C;Ths2(k)=y.CPU2_heatsink_C;
    alarm(k)=double(y.ThermalAlarm);dataValid(k)=y.DataValid;
end

out=table(t,in.CPU1_W_per_server,in.CPU2_W_per_server,in.ServerFanPWM_cmd_pct,...
    in.CRAC_PWM_cmd_pct,qCrac,qRack,recirc,Tin,Tout,Tcpu1,Tcpu2,Ths1,Ths2,...
    alarm,dataValid,in.EventCode,'VariableNames',{'time_s','CPU1_W_per_server',...
    'CPU2_W_per_server','ServerFanPWM_cmd_pct','CRAC_PWM_cmd_pct',...
    'CRAC_flow_m3_s','Rack_demand_flow_m3_s','Recirculation_fraction',...
    'Rack_inlet_C','Rack_outlet_C','CPU1_die_est_C','CPU2_die_est_C',...
    'CPU1_heatsink_C','CPU2_heatsink_C','ThermalAlarm','DataValid','EventCode'});
end
