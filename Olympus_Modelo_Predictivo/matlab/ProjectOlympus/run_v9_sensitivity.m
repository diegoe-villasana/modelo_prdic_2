function t = run_v9_sensitivity()
%RUN_V9_SENSITIVITY Steady 60%% PWM network, 150 W per CPU.
% This varies the assumed heat-pipe resistance; it is not a solid CFD fit.
p=server_cfd_coefficients(60);
rho=1.204; cp=1004.4; power=[150;150];
air=20+sum(power)/(2*rho*cp*p.TotalFlow_m3s);
g=p.LocalConductance_W_K; gr=p.RemoteConductance_W_K;
rhp=[0.03;0.05;0.08];
t=table('Size',[numel(rhp) 7],...
    'VariableTypes',repmat("double",1,7),...
    'VariableNames',{'HeatPipeR_K_W','MeanAir_C','CPU1Sink_C',...
    'CPU2Sink_C','RemoteSink_C','CPU1DieEst_C','CPU2DieEst_C'});
for k=1:numel(rhp)
    gp=1/rhp(k);
    M=[g(1)+gp 0 -gp;0 g(2)+gp -gp;-gp -gp 2*gp+gr];
    b=[power(1)+g(1)*air;power(2)+g(2)*air;gr*air];
    x=M\b;
    t{k,:}=[rhp(k) air x.' x(1)+power(1)*p.CPUToSinkResistance_K_W ...
        x(2)+power(2)*p.CPUToSinkResistance_K_W];
end
out=fullfile(fileparts(mfilename('fullpath')),'output');
if ~exist(out,'dir'),mkdir(out);end
writetable(t,fullfile(out,'v9_heatpipe_sensitivity.csv'));
assert(all(isfinite(t.CPU1DieEst_C)) && all(isfinite(t.CPU2DieEst_C)));
disp(t);
end
