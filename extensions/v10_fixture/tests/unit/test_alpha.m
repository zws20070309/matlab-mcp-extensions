classdef test_alpha < matlab.unittest.TestCase
    methods (Test)
        function addOne(tcase)
            tcase.verifyEqual(1 + 1, 2);
        end
        function roundTrip(tcase)
            tcase.verifyEqual(sum([1 2 3]), 6);
        end
    end
end
