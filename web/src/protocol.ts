export type Mode='control'|'draw'|'paused';
export interface Point {x:number;y:number}
export interface Stroke {id:string;author:string;tool:'pen'|'marker'|'arrow';color:string;width:number;points:Point[];complete:boolean}
export interface HostState {
  sessionID:string;controllerEpoch:number;inputEpoch:number;modeGeneration:number;mode:Mode;
  permissions:{control:boolean;annotate:boolean};surface:{id:string;revision:number;width:number;height:number};layerEpoch:number;reason:string;nextSequence:number;
}
export interface Operation {
  type:string; v:number; sessionID:string;controllerEpoch:number;inputEpoch:number;modeGeneration:number;
  surfaceID:string;geometryRevision:number;layerEpoch:number;operationID:string;sequence:number;
  [key:string]:unknown;
}
