:- module(lang_lists, []).

:- use_module(library('lang/compiler')).

% TODO: support more list commands
%:- query_compiler:add_command(memberchk).
%:- query_compiler:add_command(sort).
%:- query_compiler:add_command(reverse).
%:- query_compiler:add_command(list_to_set).
%:- query_compiler:add_command(max_list).
%:- query_compiler:add_command(min_list).
%:- query_compiler:add_command(sum_list).
%:- query_compiler:add_command(length).

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%% nth/3
%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% register query commands
:- query_compiler:add_command(nth).

%%
% nth/3 exposes variables of the pattern.
%
query_compiler:step_var(
		nth(_Index, _List, Pattern),
		[Key, Var]) :-
	pattern_variables_(Pattern, Vars),
	member([Key, Var], Vars).

%%
% nth/3 retrieves an a document at given index
% from some array field.
%
query_compiler:step_compile(
		nth(Index, List, _Elem),
		Context,
		Pipeline) :-
	% tell+nth is not allowed
	(	option(mode(tell), Context)
	->	throw(compilation_failed(nth(Index, List), Context)
	;	true
	),
	% option(mode(ask), Context),
	query_compiler:var_key(List, ListKey),
	atom_concat('$', ListKey, ListKey0),
	% compute steps of the aggregate pipeline
	findall(Step,
		% retrieve array element and store in 'next' field
		(	Step=['$set',['next', ['$arrayElemAt',
					[string(ListKey0),integer(Index)]]]]
		% compute the intersection of scope so far with scope of next document
		;	mng_scope_intersect('v_scope',
				string('$next.scope.time.since'),
				string('$next.scope.time.until'),
				Context, Step)
		% project new variable groundings (the ones referred to in pattern)
		;	set_vars_(Context, ListKey, Step)
		% remove the next field again
		;	Step=['$unset', string('next')]
		),
		Pipeline
	).

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%% member/2
%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% register query commands
:- query_compiler:add_command(member).

%%
% member exposes variables of the pattern.
%
query_compiler:step_var(
		member(Pattern, _List),
		[Key, Var]) :-
	pattern_variables_(Pattern, Vars),
	member([Key, Var], Vars).

%%
% member(Pattern,List) unwinds a list variable holding documents
% and exposes variables in Pattern to the rest of the pipeline.
%
query_compiler:step_compile(
		member(Pattern, List),
		Context,
		Pipeline) :-
	% tell+member is not allowed
	(	option(mode(tell), Context)
	->	throw(compilation_failed(member(Pattern, List), Context)
	;	true
	),
	% option(mode(ask), Context),
	query_compiler:var_key(List, ListKey),
	atom_concat('$', ListKey, ListKey0),
	% compute steps of the aggregate pipeline
	findall(Step,
		% copy the list to the next field for unwinding
		(	Step=['$set',['next', string(ListKey0)]]
		% at this point 'next' field holds an array of matching documents
		% that is unwinded here.
		;	Step=['$unwind',string('$next')]
		% compute the intersection of scope so far with scope of next document
		;	mng_scope_intersect('v_scope',
				string('$next.scope.time.since'),
				string('$next.scope.time.until'),
				Context, Step)
		% project new variable groundings (the ones referred to in pattern)
		;	set_vars_(Context, ListKey, Step)
		% remove the next field again
		;	Step=['$unset', string('next')]
		),
		Pipeline
	).

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%% helper
%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%
set_vars_(Context, ListKey, ['$set', SetVars]) :-
	memberchk(step_vars(QueryVars), Context),
	memberchk(outer_vars(OuterVars), Context),
	memberchk([ListKey, list(_,Pattern)], OuterVars),
	pattern_variables_(Pattern,ListVars),
	set_vars_1(QueryVars, ListVars, SetVars).

%%
set_vars_1([], [], []) :- !.
set_vars_1([X|Xs], [Y|Ys], [Z|Zs]) :-
	X=[Key,_],
	Y=[ListKey,_],
	atom_concat('$next.', ListKey, Val),
	Z=[Key,string(Val)],
	set_vars_1(Xs, Ys, Zs).

%%
pattern_variables_(Pattern, Vars) :-
	term_variables(Pattern, PatternVars),
	pattern_variables_1(PatternVars, Vars).

pattern_variables_1([], []) :- !.
pattern_variables_1([X|Xs], [[Key,X]|Ys]) :-
	query_compiler:var_key(X,Key),
	pattern_variables_1(Xs, Ys).
