package com.axis {
  import flash.external.ExternalInterface;

  public class Logger {
    public static const STREAM_ERRORS:String = "";

    public static function log(... args):void {
      if (Player.config.debugLogger) {
        trace.apply(null, args);
      }
        var message:String = "";
        for (var i:String in args) {
          message += ' ';
          if ( !args[i] is String) {
              message += args[i].toString();
          } else {
              message += args[i]
          }
        }
        ExternalInterface.call("console.log", message);
    }
  }
}
