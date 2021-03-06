%===============================================================================
%
% Title:        remAL
%                                                             
% Project:      Transformation of HYSDEL model into PWA model
%
% Purpose:      Detect and remove algebraic loops
%
% Input:        S: structure containing MLD model generated by HYSDEL compiler 
%
% Output:       structure S with
%                   * nxr real states
%                   * nxb binary states
%                   * nur real inputs
%                   * nub binary inputs,
%                   where n?or are original real ones,
%                       n?ar are aux. real ones, 
%                       n?ob are original binary ones and
%                       n?ab are aux. binary ones.
%                   in general: nxr = nxor + nxar etc.
%
% Overview:     1.) check whether there are algebraic loops
%               2.) build vertex table
%               3.) build adjacency matrix
%               4.) find feedback arc set
%               5.) set computational order
%               6.) add auxiliary inputs
%               7.) replace feedback arcs by equality constraints
%
% Authors:      Tobias Geyer <geyer@control.ee.ethz.ch>
                                                                      
% History:      date        subject                                       
%               2003.01.??  initial version
%
% Requires:     findFAS,
%               syminfo
%
% Contact:      Tobias Geyer
%               Automatic Control Laboratory
%               ETH Zentrum, CH-8092 Zurich, Switzerland
%
%               geyer@aut.ee.ethz.ch
%
%               Comments and bug reports are highly appreciated
%
%===============================================================================

function S = remAL(S)

% number of original real and binary inputs
S.nuor = S.nur; 
S.nuob = S.nub;     



% 1.) are there algebraic loops?
% --------------------------------------------------------------------

% i.e. are there entries in the symtable with computational order == 0?
algLoops = 0;
for i=1:length(S.symtable)
    if S.symtable{i}.computable_order == 0
        algLoops = 1;
        disp('Found implicitly defined variable(s) - possibly an algebraic loop.')
        S.algLoop = 1;
        break;
    end;
end;

% if there are no algebraic loops, return
if algLoops == 0, 
    disp('No algebraic loops detected.');
    return; 
end;



% 2.) build vertex table (from symtable)
% --------------------------------------------------------------------

vertexTable = {}; j = 0;
for i=1:length(S.symtable)
    if S.symtable{i}.computable_order >= 0
        % this is a variable (not a constant etc.)
        
        % add to vertexMap
        j = j+1;
        vertexTable{j}.name = S.symtable{i}.name;
        vertexTable{j}.type = S.symtable{i}.type;
        vertexTable{j}.kind = S.symtable{i}.kind;
    end;
end;



% 3.) build adjacency matrix (using rowinfo)
% --------------------------------------------------------------------

% go through all rowinfo entries and add dependencies 
% by drawing an edge from depends to defines
% i.e. put a '1' at A(depends, defines)
% remark: we go only through rowinfo.ineq
%         rowinfo.state_upd holds the state-update functions
%         rowinfo.output holds the output functions
%         both do not contribute to the partitioning, to the 
%         computational order and are not part of loops
% ok: for now, we also go through rowinfo.output

% initialize
A = zeros(length(vertexTable));

% rowinfo.ineq
for i=1:length(S.rowinfo.ineq)
    if strcmp(S.rowinfo.ineq{i}.item_type, 'Cont_must')
        % continuous MUST section
        % these inequalities do not define variables - ignore them at this
        % point
    else
        defines = S.rowinfo.ineq{i}.defines;
        depends = S.rowinfo.ineq{i}.depends;
        
        v_term = giveVertex(defines, vertexTable);
        if isnan(v_term), 
            error('Found undefined variable - it is probably defined in the MUST section');
        end;
        for j=1:length(depends)
            v_ini = giveVertex(depends{j}, vertexTable);
            A(v_ini, v_term) = 1;
        end;
    end;
end;

% rowinfo.output
for i=1:length(S.rowinfo.output)
    defines = S.rowinfo.output{i}.defines;
    depends = S.rowinfo.output{i}.depends;
    
    v_term = giveVertex(defines, vertexTable);
    for j=1:length(depends)
        v_ini = giveVertex(depends{j}, vertexTable);
        A(v_ini, v_term) = 1;
    end;
end;



% 4.) find feedback arc set (FAS)
% --------------------------------------------------------------------

[FAS, s_fas] = findFAS(A);
% where FAS: feedback arc set: FAS(i,:) contains the i-th feedback arc from vertex
%            FAS(i,1) to vertex FAS(i,2)
% s_fas: vertex sequence corresponding to A_fas (the i-th entry of s_fas contains the number
%        of the i-th vertex and corresponds to the i-th row and column of A, the 
%        vertexTable maps the numbers of the vertices to their variable names)



% 5.) set computational order (in symtable)
% --------------------------------------------------------------------

% remark: We update the computational order according to the vertex sequence s_fas.
%         Therefore, every variable has a unique computational order and if there is more
%         than one inut, inputs also have computational orders greater than 1.

for i=1:length(s_fas)
    % name of variable of which we want to update the comp. order
    name = vertexTable{s_fas(i)}.name;
    
    % find the corresponding entry in the symboltable
    [info, symbtable_i] = syminfo(S,name);
    if length(info) ~= 1, error('corrupted symboltable')
    else                  info = info{1};    
    end
    
    % update computational order
    S.symtable{symbtable_i}.computable_order = i;
end;




% 6.) add aux. inputs
% --------------------------------------------------------------------

% remark: update the symboltable for u and update B1, D1 and E1
%         keep the inputs sorted (first all real inputs, then the binary 
%         inputs)

S.nuar = 0; S.nuab = 0;             % number of aux. real, binary inputs
for i=1:size(FAS,1)
    
    v_source = vertexTable{FAS(i,1)};
    
    % does an aux. input for v_source already exist?
    % check the symboltable
    info = syminfo(S, [v_source.name '_aux']);
    if isempty(info)
        % we haven't found any, so we have to create a new one:
        S = CreateAuxInput(S, v_source.name);
    end;
    
end;




% 7.) replace feedback arcs by equality constraints
% --------------------------------------------------------------------

for i=1:size(FAS,1)
    
    % the edge from v_source to v_sink has to be broken
    v_source = vertexTable{FAS(i,1)};       % v_depends = v_source
    v_sink   = vertexTable{FAS(i,2)};       % v_defines = v_sink
    
    % find the index=column of the aux. input
    info = syminfo(S, [v_source.name '_aux']);
    if isempty(info) | (length(info) > 1)
        error('Symboltable entry of aux. input is wrong')
    end;
    u_col = info{1}.index;
        
    % remove loop and add equality constraint (update E2 or E3 or E4)
    S = updateIneqConstr(S, v_source.name, v_source.kind, v_sink.name, u_col);
        
end;



% final remarks and open questions:
% 1.) we do not update or change the adjancency matrix or the vertexTable
%     as they are of no importance anymore and are not used later
% 2.) we do not update rowinfo.output
%     as the equality constraint assigns the proper value to the output
% 3.) we do not update the state-update matrices
%     they are updated in the function 'push' after resolving the equality constraint
% 4.) should we also update rowinfo?
%     --> no...

return



% --------------------------------------------------------------------

function v = giveVertex(vertexName, vertexTable)
% given the name of a vertex, determine the number of the corresponding entry
% in the vertexTable
v = 1;
while v <= length(vertexTable)
    if strcmp( vertexTable{v}.name, vertexName )
        return;
    else
        v = v+1;
    end;
end;
v = NaN;
return




% --------------------------------------------------------------------

function S = CreateAuxInput(S, sourceName)
% create new aux. input (either real or binary) 
% with the following entries:
%     name: name of source vertex + '_aux'
%     type: same as source vertex
%     line_of_declaration: NaN
%     line_of_first_use: NaN
%     computable_order: 1
%     kind: 'u'
%     index: if real: S.nur+1, if binary: S.nu+1
%     defined: NaN;
%     bounds: same as source vertex
%     aux_input: 1
% update nu, nur, nuar, nub and nuab
% add 0-column at index of aux. input for B1, D1 and E1

aux_vertex = syminfo(S, sourceName);
if length(aux_vertex) ~= 1, error('corrupted symboltable')
else                        aux_vertex = aux_vertex{1};    
end
aux_vertex.name = [sourceName '_aux'];
aux_vertex.line_of_declaration = NaN;
aux_vertex.line_of_first_use = NaN;
aux_vertex.computable_order = 1;    
aux_vertex.kind = 'u';   
if aux_vertex.type == 'r'
    aux_vertex.index = S.nur + 1;
    S.nur = S.nur+1;
    S.nuar = S.nuar + 1;
else
    aux_vertex.index = S.nu + 1;
    S.nub = S.nub+1;
    S.nuab = S.nuab+1;
end;
S.nu = S.nu+1;
aux_vertex.defined = NaN;
aux_vertex.aux_input = 1;

% for all inputs with index >= the index of the new aux. input:
% increase the index by one
for s=1:length(S.symtable)
    if S.symtable{s}.kind == 'u'
        if S.symtable{s}.index >= aux_vertex.index
            S.symtable{s}.index = S.symtable{s}.index + 1;
        end;
    end;
end;

% add new aux. input to the symboltable
S.symtable{end+1} = aux_vertex;

% update B1, D1 and E1 by adding a column with zeros at position given by
% aux_vertex.index
c = aux_vertex.index;
S.B1 = [S.B1(:,1:c-1) zeros(S.nx,1) S.B1(:,c:end)];
S.D1 = [S.D1(:,1:c-1) zeros(S.ny,1) S.D1(:,c:end)];
S.E1 = [S.E1(:,1:c-1) zeros(S.ne,1) S.E1(:,c:end)];

return


% --------------------------------------------------------------------

function S = updateIneqConstr(S, sourceName, sourceKind, sinkName, u_col)
% update the inequality constraint matrices:
% 1.) break the feedback arc
% 2.) add one equality constraint (as two inequality constraints)
%
% inputs: S
%         sourceName = variable name of source vertex
%         sourceKind = kind of variable: d, z, x
%         sinkName   = variable name of sink vertex
% output: S
%
% remark: use rowinfo.ineq,
%         where the i-th rowinfo.ineq-entry describes the i-th ineq. constraint 

% first get the column of the 'depends'-variable
info = syminfo(S, sourceName);
if isempty(info) | (length(info) > 1)
    error('Symboltable entry of aux. input is wrong')
end;
dep_col = info{1}.index;

% find all rows of the ineq. constraints that contain the feedback arc
for r=1:length(S.rowinfo.ineq)
    row = S.rowinfo.ineq{r};
    % does the 'defines'-variable name match the sink?
    if strcmp(row.defines, sinkName)
        % check if there is any 'depends'-variable name that matches the source
        for d=1:length(row.depends)
            if strcmp(row.depends(d), sourceName)
                % we have to modify the r-th row in the ineq. constraints
                % i.e. move the entry of the 'depends'-variable to the new aux. input variable
                % move the entry from E2, E3 or E4 to E1
                % and change the sign for d and z (as we move on the other side of the equation)
                if sourceKind == 'd'
                    S.E1(r, u_col) = S.E2(r, dep_col) * (-1);
                    S.E2(r, dep_col) = 0;
                elseif sourceKind == 'z'
                    S.E1(r, u_col) = S.E3(r, dep_col) * (-1);
                    S.E3(r, dep_col) = 0;
                %elseif sourceKind == 'x'
                    % distinguish between x real and binary
                    %S.E1(r, u_col) = S.E4(r, dep_col);
                    %S.E4(r, dep_col) = 0;
                else
                    error('Unknown kind of source vertex')
                end;
            end;
        end;
    end;
end;

% add two inequality constraints:
% d, z, -x <= u_aux
% -d, -z, x <= -u_aux
% the column of d, z, and x is given by dep_col,
% the column of the aux. input is given by u_col.

% add two zero lines to the inequalities
S.E1 = [S.E1; zeros(2,S.nu)];
S.E2 = [S.E2; zeros(2,S.nd)];
S.E3 = [S.E3; zeros(2,S.nz)];
S.E4 = [S.E4; zeros(2,S.nx)];
S.E5 = [S.E5; zeros(2,1)];
S.ne = S.ne+2;

% write in these two last lines the ineq. constraints
S.E1(S.ne-1:S.ne, u_col) = [1; -1];
if sourceKind == 'd'
    S.E2(S.ne-1:S.ne, dep_col) = [1; -1];
elseif sourceKind == 'z'
    S.E3(S.ne-1:S.ne, dep_col) = [1; -1];
%elseif sourceKind == 'x'    
    % distinguish between real and binary states
    %S.E4(S.ne-1:S.ne, dep_col) = [-1; 1];
else
    error('Unknown kind of source vertex')
end;

% update rowinfo.ineq
entry = [];
entry.group = NaN;
entry.subgroup = NaN;
entry.subindex = NaN;
entry.section = '';         % ?
entry.item_type = 'AL_must';
entry.defines = sinkName;
entry.depends = [sourceName '_aux'];

S.rowinfo.ineq{end+1} = entry;
S.rowinfo.ineq{end+1} = entry;

return