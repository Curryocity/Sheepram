package app_test

import "core:testing"
import app "../../src/app"
import opt "../../src/optimizer"

@(test)
constraint_filters_follow_existing_status_thresholds :: proc(t: ^testing.T) {
	cases := [?]struct {
		margin: f64,
		cmp: opt.Cmp,
		discrete: bool,
		status: app.Constraint_Result_Status,
	}{
		{-2*opt.ACCEPT_TOL, .Less, false, .Violated},
		{-opt.ACCEPT_TOL, .Less, false, .Active},
		{-0.5*opt.ACCEPT_TOL, .Less, false, .Active},
		{-0.5*opt.ACCEPT_TOL, .Less, true, .Violated},
		{0, .Less, true, .Active},
		{opt.ACCEPT_TOL, .Less, false, .Active},
		{2*opt.ACCEPT_TOL, .Less, false, .Inactive},
		{2*opt.ACCEPT_TOL, .Less, true, .Inactive},
		{0, .Equal, false, .Active},
		{opt.ACCEPT_TOL, .Equal, true, .Active},
		{2*opt.ACCEPT_TOL, .Equal, false, .Violated},
	}
	for item in cases {
		result := opt.Constraint_Result{margin = item.margin, cmp = item.cmp}
		testing.expect_value(t, app.constraint_result_status(result, item.discrete), item.status)
		testing.expect(t, app.constraint_result_visible(result, item.discrete, .All))
		testing.expect_value(t, app.constraint_result_visible(result, item.discrete, .Violated_Only), item.status == .Violated)
		testing.expect_value(t, app.constraint_result_visible(result, item.discrete, .Inactive_Only), item.status == .Inactive)
	}
}
