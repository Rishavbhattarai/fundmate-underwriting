trigger IntegrationLogEventTrigger on Integration_Log_Event__e(after insert) {
    IntegrationLogEventHandler.handle(Trigger.new);
}
