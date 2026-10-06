classdef test_gamma < matlab.unittest.TestCase
    methods (Test)
        function pipelinePass(tcase)
            tcase.verifyEqual(numel(linspace(0, 1, 11)), 11);
        end
        function pipelineFail(tcase)
            % deliberately wrong on purpose: this fixture must produce a red
            % case so the failure path of suite_run gets measured, not assumed
            tcase.verifyEqual(pi, pi, 'AbsTol', 1e-6);
        end
    end
end
