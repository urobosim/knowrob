/*
  Copyright (C) 2019 Daniel Beßler
  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:
      * Redistributions of source code must retain the above copyright
        notice, this list of conditions and the following disclaimer.
      * Redistributions in binary form must reproduce the above copyright
        notice, this list of conditions and the following disclaimer in the
        documentation and/or other materials provided with the distribution.
      * Neither the name of the <organization> nor the
        names of its contributors may be used to endorse or promote products
        derived from this software without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
  DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

:- module(knowrob_ros_service,
    [
      ros_service/3,
      ros_service_call/3
    ]).

:- use_module(library('semweb/rdf_db')).
:- use_module(library('semweb/rdfs')).
:- use_module(library('semweb/owl')).
:- use_module(library('knowrob/ros')).

:- rdf_db:rdf_register_ns(ros, 'http://www.ease-crc.org/ont/ROS.owl#', [keep(true)]).

:- rdf_meta ros_service(r, ?, ?),
            ros_service_call(r, r, r).

%% ros_service(+Service,?Name,?Path) is det.
%
ros_service(Service,Name,Path) :-
  rdf_has(Service,dul:concretelyImplements,ServiceInterface),
  rdf_has_prolog(Service,ros:hasServiceName,Name),
  rdf_has_prolog(ServiceInterface,ros:hasTypePath,Path).

%% ros_message_slot_type(+Msg,?SlotName,?SlotType) is det.
%
ros_message_slot_type(Msg,SlotName,SlotType) :-
  rdf_has(Msg,dul:realizes,Msg_Type),
  rdf_has(Msg_Type,dul:hasPart,SlotType),
  rdf_has_prolog(SlotType,ros:hasSlotName,SlotName),!.

% % % % % % % % % % % % % % % % % % % % % % % % % % % % 
% % % % % % % % % % % call a service
% % % % % % % % % % % % % % % % % % % % % % % % % % % % 

%% ros_service_call(+Service, +Request, +Response) is semidet.
%
ros_service_call(Service, Request, Response) :-
  ros_service(Service, ServicePath, ServiceName),
  ( ros_request_encode(Service, Request, Request_json) ;
    throw(ros_error(ros:'UNGROUNDABLE_REQUEST')) ),
  ( ros_json_wrapper(ServiceName, ServicePath, Request_json, Response_json) ;
    throw(ros_error(ros:'SERVICE_NODE_UNREACHABLE')) ),
  ( ros_response_decode(Response_json, Response) ;
    throw(ros_error(ros:'UNINTERPRETABLE_REQUEST')) ).

%% ros_request_encode(+Service, +Request, -Request_json) is det.
%
ros_request_encode(_Service, Request, Request_json) :-
  ros_entity_to_prolog(Request, Request_dict),
  %%%%%%%%%
  %%%%% encode as JSON dict
  %%%%%%%%%
  with_output_to(atom(Request_json), 
    json_write_dict(current_output, Request_dict)
  ).

%% ros_response_decode(+Response_json, +Response) is det.
%
ros_response_decode(Response_json, Response) :-
  %%%%%%%%%
  %%%%% Encode response as list of key-value pairs
  %%%%%%%%%
  atom_to_chars(Response_json,Response_chars),
  open_chars_stream(Response_chars, Response_Stream),
  json_read_dict(Response_Stream, Response_dict),
  dict_pairs(Response_dict,_,Response_pairs),
  %%%%%%%%%
  %%%%% Encode response as list of pairs
  %%%%%%%%%
  forall((
    member(SName-SValue, Response_pairs),
    ros_message_slot_type(Response, SName, DataSlot)),(
    %%%%%%%%%
    %%%%% Create symbolic representation for response field
    %%%%%%%%%
    once((
      rdf_has(DataSlot,dul:hasPart,SlotType),
      ros_type_path(SlotType,SType)
    )),
    owl_create_ros_entity(SType,SValue,Slot),
    rdf_assert(Response,dul:hasPart,Slot),
    rdf_assert(Slot,dul:realizes,DataSlot),
    forall(
      rdf_has(DataSlot,dul:isClassifiedBy,R),
      classify_message_value(Slot,R)
    )
  )).

classify_message_value(Slot,R) :-
  ( rdfs_individual_of(Slot,ros:'PrimitiveValue') ;
    rdfs_individual_of(Slot,ros:'PrimitiveArray') ), !,
  rdf_has(Slot, dul:hasRegion, Region),
  rdf_assert(Region,dul:isClassifiedBy,R).
classify_message_value(Slot,R) :-
  rdf_assert(Slot,dul:isClassifiedBy,R).

% % % % % % % % % % % % % % % % % % % % % % % % % % % % 
% % % % % % % % % % % OWL to ROS message dict
% % % % % % % % % % % % % % % % % % % % % % % % % % % % 

%% TODO: also consider some custom message factory functions,
%%       e.g. to create more sane symbolic representation of pose
%ros_message_to_prolog('geometry_msgs/Pose',Msg_owl,Msg_dict) :- ...
%ros_message_to_prolog('geometry_msgs/Point',Msg_owl,Msg_dict) :- ...
%owl_create_ros_entity('geometry_msgs/Pose',Dict,Msg_owl) :- ...
%owl_create_ros_entity('geometry_msgs/Point',Dict,Msg_owl) :- ...

ros_message_to_prolog(_, Msg, Msg_dict) :-
  rdf_has(Msg,dul:realizes,Msg_Type),
  findall(SName-[SType,SValue], (
    %%%%%%%%%
    %%%%% For each slot of the message type
    %%%%%%%%%
    rdf_has(Msg_Type,dul:hasPart,DataSlot),
    rdf_has_prolog(DataSlot, ros:hasSlotName, SName),
    once((
      rdf_has(DataSlot,dul:hasPart,SlotType),
      ros_type_path(SlotType,SType)
    )),
    %%%%%%%%%
    %%%%% Infer the value of the slot
    %%%%%%%%%
    once((
      rdf_has(Msg, dul:hasPart, Filler),
      rdf_has(Filler, dul:realizes, SlotType)
    )),
    ros_entity_to_prolog(Filler, SValue)
  ), Pairs),
  % create a dict 'msg{key1:[type1,value1],...}'
  dict_pairs(Msg_dict,msg,Pairs).

ros_entity_to_prolog(Msg, Msg_dict) :-
  rdfs_individual_of(Msg,ros:'Message'),!,
  rdf_has(Msg,dul:realizes,Msg_Type),
  rdf_has_prolog(Msg_Type,ros:hasTypePath,TypePath),
  ros_message_to_prolog(TypePath, Msg, Msg_dict).

ros_entity_to_prolog(PrimitiveValue_owl, PrimitiveValue_pl) :-
  ( rdfs_individual_of(PrimitiveValue_owl,ros:'PrimitiveValue') ;
    rdfs_individual_of(PrimitiveValue_owl,ros:'PrimitiveArray') ),!,
  rdf_has(PrimitiveValue_owl,dul:hasRegion,Region),
  once((
    rdf_has_prolog(Region,dul:hasRegionDataValue,PrimitiveValue_pl);
    PrimitiveValue_pl = Region )).

ros_entity_to_prolog(Array_owl, Array_pl) :-
  rdfs_individual_of(Array_owl,ros:'MessageArray'),!,
  owl_array_to_list(Array_owl, Iri_List),
  findall(X, (
    member(Iri,Iri_List),
    ros_entity_to_prolog(Iri,X)),
    Array_pl).

% % % % % % % % % % % % % % % % % % % % % % % % % % % % 
% % % % % % % % % % % ROS message dict to OWL
% % % % % % % % % % % % % % % % % % % % % % % % % % % % 

owl_create_ros_entity(Msg_TypePath,Msg_dict,Msg_owl) :-
  is_dict(Msg_dict),!,
  rdf_instance_from_class(ros:'Message',Msg_owl),
  ( ros_message_type(Msg_Type, Msg_TypePath) ->
    rdf_assert(Msg_owl,dul:realizes,Msg_Type) ; true ),
  dict_pairs(Msg_dict,_,Msg_pairs),
  forall(member(SName-[SType,SValue], Msg_pairs),(
    owl_create_ros_entity(SType,SValue,Val_owl),
    rdf_assert_prolog(Val_owl,ease:hasNameString,SName),
    rdf_assert(Msg_owl,dul:hasPart,Val_owl)
  )).

owl_create_ros_entity(Type,Value,PrimitiveValue) :-
  ros_primitive_type(Type, XSDType),!,
  owl_create_atomic_region(XSDType, Value, Region),
  rdf_instance_from_class(ros:'PrimitiveValue',PrimitiveValue),
  rdf_assert(PrimitiveValue,dul:hasRegion,Region).

owl_create_ros_entity(Array_type,Val_list,PrimitiveArray) :-
  is_list(Val_list),
  term_to_atom(array(Type),Array_type),
  ros_primitive_type(Type, _),!,
  ros_array_type(Type, ArrayType),
  % list to atom
  findall(A, (member(X,Val_list), term_to_atom(X,A)), Atoms),
  atomic_list_concat(Atoms, ' ', ArrayData),
  % create symbols
  rdf_instance_from_class(ros:'PrimitiveArray',PrimitiveArray),
  rdf_instance_from_class(dul:'Region',Region),
  rdf_assert(Region,dul:hasRegionDataVaue,
             literal(type(ArrayType,ArrayData))),
  rdf_assert(PrimitiveArray,dul:hasRegion,Region).

owl_create_ros_entity(_Array_type,Val_list,Array_owl) :-
  is_list(Val_list),
  findall(Val_owl, (
    member(X,Val_list),
    owl_create_ros_entity(X,Val_owl)),
    Msg_list),
  owl_create_array(Msg_list, Array_owl).
