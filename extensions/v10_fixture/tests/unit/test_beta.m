classdef test_beta < matlab.unittest.TestCase
    methods (Test)
        function matrixShape(tcase)
            m = [1 2; 3 4];
            tcase.verifyEqual(size(m), [2 2]);
        end
    end
end
