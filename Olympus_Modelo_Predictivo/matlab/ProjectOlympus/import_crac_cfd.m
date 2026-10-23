function data = import_crac_cfd(modelFolder)
%IMPORT_CRAC_CFD Load the validated OpenFOAM CRAC raised-floor response.
if nargin == 0
    modelFolder = fullfile(fileparts(mfilename('fullpath')),'data');
end
data.response = readtable(fullfile(modelFolder,'crac_step_response.csv'));
data.model = jsondecode(fileread(fullfile(modelFolder,'crac_identified_model.json')));
assert(strcmp(data.model.status,'QA_PASS'),'CRAC CFD identification did not pass QA.');
end
