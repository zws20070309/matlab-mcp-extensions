function out = mcp_demo_fail(params) %#ok<STOUT,INUSD>
%MCP_DEMO_FAIL Always throws. Used to verify the failure reporting path.
error('mcp:demoFail', '[mcp:demoFail] intentional failure for testing');
end
