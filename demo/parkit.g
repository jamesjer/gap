ParkitManagerDefaultOpts := rec(maxRunningTasks := 4);

if not IsBound(InfoParkit) then
    DeclareInfoClass("InfoParkit");
fi;


NewSimpleMap := function()
    return rec(keys := [], data := []);
end;

SizeSimpleMap := function(sm)
    return Length(sm.keys);
end;

AddToSimpleMap := function(sm, key, val)
    local   p;
    p := PositionSorted(sm.keys,key);
    Add(sm.keys, key, p);
    Add(sm.data, val, p);
end;

LookupSimpleMap := function(sm, key)
    local   p;
    p := Position(sm.keys, key);
    if p = fail then
        return fail;
    else
        return sm.data[p];
    fi;
end;

RemoveFromSimpleMap := function(sm, key)
    local   p;
    p := Position(sm.keys, key);
    if p <> fail then
        Remove(sm.keys, p);
        Remove(sm.data, p);
    fi;
end;

RepresentativeKeySimpleMap := function(sm)
    if Length(sm.keys) = 0 then
        return fail;
    fi;
    return sm.keys[1];
end;


BeParkitManager := function(manager)
    local   checkQueue,  command,  op,  fun,  task,  newtask,  
            inputsOK,  waitCount,  input,  id,  inobj,  outputsOK,  
            output,  outobj,  r,  inpobj,  obj,  createdObj;
    checkQueue := function()
        Info(InfoParkit,2,"running ",SizeSimpleMap(manager.runningTasks)," runnable ",SizeSimpleMap(manager.queuedTasks));
        if SizeSimpleMap(manager.runningTasks) < manager.opts.maxRunningTasks and
           SizeSimpleMap(manager.queuedTasks) > 0 then
            id := RepresentativeKeySimpleMap(manager.queuedTasks);
            task := LookupSimpleMap(manager.queuedTasks, id);
            RemoveFromSimpleMap(manager.queuedTasks, id);
            AddToSimpleMap(manager.runningTasks, id, task);
            Assert(2, task.taskID = id);
            task.temps := NewDictionary("abc",true);
            Info(InfoParkit,2,"Launching ",id);
            CreateThread(task.fun, id, manager.channel, 
                   List(task.inputs, id -> LookupSimpleMap(manager.objects,id).value));
        fi;
    end;
    while true do
        command := ReceiveChannel(manager.channel);
        Info(InfoParkit,2, command.op," from ",command.taskID);
        Info(InfoParkit,3,command);
        if not IsRecord(command) or 
           not IsBound(command.op) or 
           not IsString(command.op) then
            Info(InfoParkit,1,"Bad command ",command);
            continue;
        fi;
        op := LowercaseString(command.op);
        if op = "register" then
            if not IsBound(command.key) or 
               not IsString(command.key) or
               not IsBound(command.func) or
               not IsFunction(command.func) then
                Info(InfoParkit,1,"Bad arguments to register");
                continue;
            fi;
            Info(InfoParkit,2,command.key);
            AddDictionary(manager.fns, command.key, command.func);
        elif op = "submit" then
            if not IsBound(command.type) or 
               not IsString(command.type) or
               not IsBound(command.ins) or
               not IsList(command.ins) or
               not IsBound(command.outs) or
               not IsList(command.outs) or
               not IsBound(command.taskID) or
               not IsInt(command.taskID) or 
               command.taskID < 0 then
                Info(InfoParkit,1,"Bad arguments to submit");
                continue;
            fi;
            Info(InfoParkit,2,command.type);
            fun := LookupDictionary(manager.fns,command.type);
            if fun = fail then
                Info(InfoParkit,1,"Unknown function key");
                continue;
            fi;
            if command.taskID  = 0 then
                task := false;
            else
                task := LookupSimpleMap(manager.runningTasks, command.taskID);
                if task = fail then
                    Info(InfoParkit,1,"Unknown submitter task");
                    continue;
                fi;
            fi;
            newtask := rec(taskID := manager.nextTaskID, fun := fun, created := []);
            manager.nextTaskID := manager.nextTaskID+1;
            if task = false and (Length(command.ins) > 0 or Length(command.outs) > 0) 
               then
                Info(InfoParkit,1,"An external task cannot have inputs or outputs");
                continue;
            fi;
            newtask.inputs := [];
            inputsOK := true;
            waitCount := 0;
            for input in command.ins do
                if IsInt(input) then
                    if input < 1 or input > Length(task.inputs) then
                        Info(InfoParkit,1,"Unknown input number");
                        inputsOK := false;
                        break;
                    fi;
                    id := task.inputs[input];
                elif IsString(input) then
                    input := LowercaseString(input);
                    id := LookupDictionary(task.temps, input);
                    if id = fail then
                        Info(InfoParkit,1,"Unknown temporary object");
                        inputsOK := false;
                        break;
                    fi;
                fi;
                Add(newtask.inputs, id);
                inobj := LookupSimpleMap(manager.objects, id);
                Assert(1,inobj <> fail);
                AddSet(inobj.readers, newtask.taskID);
                if not IsBound(inobj.value) then 
                    waitCount := waitCount+1;
                fi;
            od;
            if not inputsOK then
                continue;
            fi;
            newtask.outputs := [];
            outputsOK := true;
            for output in command.outs do
                if IsInt(output) then
                    if output < 1 or output > Length(task.outputs) then
                        Info(InfoParkit,1,"Unknown output number");
                        outputsOK := false;
                        break;
                    fi;
                    id := task.outputs[output];
                elif IsString(output) then
                    output := LowercaseString(output);
                    id := LookupDictionary(task.temps, output);
                    if id <> fail then
                        Info(InfoParkit,1,"Duplicate temporary object");
                        outputsOK := false;
                        break;
                    fi;
                    id := manager.nextObjectID;
                    manager.nextObjectID := manager.nextObjectID+1;
                    AddDictionary(task.temps, output, id);
                    AddToSimpleMap(manager.objects,id, 
                            rec(readers := []));
                fi;
                Add(newtask.outputs, id);
                outobj := LookupSimpleMap(manager.objects,id);
                outobj.creator := command.taskID;
                AddSet(task.created, id);
                Assert(1,outobj <> fail);
            od;
            if not outputsOK then
                continue;
            fi;
            if IsBound(command.onComplete) then
                if not IsFunction(command.onComplete) then
                    Info(InfoParkit,1,"Bad value for onComplete");
                    continue;
                fi;
                newtask.onComplete := command.onComplete;
            fi;
            if waitCount > 0 then
                newtask.waitCount := waitCount;
                AddToSimpleMap(manager.waitingTasks, newtask.taskID, newtask);
            else
                AddToSimpleMap(manager.queuedTasks, newtask.taskID, newtask);
                if SizeSimpleMap(manager.queuedTasks) = 1 then
                    checkQueue();
                fi;
            fi;
        elif op = "releaseinput" then
            if not IsBound(command.which) or 
               not IsPosInt(command.which) or
               not IsBound(command.taskID) or
               not IsInt(command.taskID) or 
               command.taskID < 0 then
                Info(InfoParkit,1,"Bad arguments to submit");
                continue;
            fi;
            task := LookupSimpleMap(manager.runningTasks, command.taskID);
            if task = fail then
                Info(InfoParkit,1,"Unknown task releasing input");
                continue;
            fi;            
            if command.which > Length(task.inputs) then
                Info(InfoParkit,1,"Task releasing input it doesn't have");
                continue;
            fi;
            inobj := LookupSimpleMap(manager.objects, task.inputs[command.which]);
            Assert(1,inobj <> fail);
            RemoveSet(inobj.readers, command.taskID);
            if Length(inobj.readers) = 0 and not IsBound(inobj.creator) then
                Unbind(inobj.value);
            fi;
        elif op = "provideoutput" then
            if not IsBound(command.which) or 
               not IsPosInt(command.which) or
               not IsBound(command.value) or
               not IsBound(command.taskID) or
               not IsInt(command.taskID) or 
               command.taskID < 0 then
                Info(InfoParkit,1,"Bad arguments to provideOutput");
                continue;
            fi;
            task := LookupSimpleMap(manager.runningTasks, command.taskID);
            if task = fail then
                Info(InfoParkit,1,"Unknown task providing output");
                continue;
            fi;            
            if command.which > Length(task.outputs) then
                Info(InfoParkit,1,"Task providing output it doesn't have");
                continue;
            fi;
            outobj := LookupSimpleMap(manager.objects, task.outputs[command.which]);
            Assert(1,outobj <> fail);
            if IsBound(outobj.creator) or Length(outobj.readers) > 0 then
                outobj.value := command.value;
            fi;
            for r in outobj.readers do
                task := LookupSimpleMap(manager.waitingTasks, r);
                Assert(1,task <> fail);
                task.waitCount := task.waitCount -1;
                if task.waitCount = 0 then
                    AddToSimpleMap(manager.queuedTasks, r, task);
                    RemoveFromSimpleMap(manager.waitingTasks,r);
                    if SizeSimpleMap(manager.queuedTasks) = 1 then
                        checkQueue();
                    fi;
                fi;
            od;
        elif op = "finished" then
            if not IsBound(command.taskID) or
               not IsInt(command.taskID) or 
               command.taskID < 0 then
                Info(InfoParkit,1,"Bad arguments to finished");
                continue;
            fi;
            task := LookupSimpleMap(manager.runningTasks, command.taskID);
            if task = fail then
                Info(InfoParkit,1,"Unknown task reporting completion");
                continue;
            fi;            
            for inpobj in task.inputs do 
                obj := LookupSimpleMap(manager.objects, inpobj);
                RemoveSet(obj.readers, command.taskID);
                if Length(obj.readers) = 0 and not IsBound(obj.creator) then
                    Unbind(obj.value);
                fi;
            od;
            for createdObj in task.created do
                obj := LookupSimpleMap(manager.objects, createdObj);
                Unbind(obj.creator);
                if Length(obj.readers) = 0 then
                    Unbind(obj.value);
                fi;
            od;
            if IsBound(task.onComplete) then
                task.onComplete();
            fi;
            RemoveFromSimpleMap(manager.runningTasks, command.taskID);
            checkQueue();
        elif op = "quit" then
            return;
        else
            Info(InfoParkit,1,"Unknown command");
            continue;
        fi;
    od;
end;

CreateParkitManager := function(arg)
    local   opts,  n,  manager,  channel,  fns,  runningTasks,  
            queuedTasks,  waitingTasks,  objects,  nextTaskID;
    if Length(arg) = 0 then
        opts := rec();
    elif Length(arg) = 1 then
        opts := ShallowCopy(arg[1]);
    else
        Print("usage: CreateParkitManager([<options record>])");
    fi;
    
    for n in RecNames(ParkitManagerDefaultOpts) do
        if not IsBound(opts.(n)) then
            if ParkitManagerDefaultOpts.(n) <> fail then
                opts.(n) := ParkitManagerDefaultOpts.(n);
            fi;
        fi;
    od;
    
    manager := rec( opts := opts,
                    channel := CreateChannel(),
                    fns := NewDictionary("name", true),
                    runningTasks := NewSimpleMap(),
                    queuedTasks := NewSimpleMap(),
                    waitingTasks := NewSimpleMap(),
                    objects := NewSimpleMap(),
                    nextObjectID := 1,
                    nextTaskID := 1);
    
    manager.thread := CreateThread(BeParkitManager,manager );
    
    return manager;
end;



    

           
        
