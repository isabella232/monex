xquery version "3.0";

import module namespace notification="http://exist-db.org/apps/monex/notification" at "notification.xql";
import module namespace config="http://exist-db.org/apps/admin/config" at "config.xqm";
import module namespace http="http://expath.org/ns/http-client" at "java:org.exist.xquery.modules.httpclient.HTTPClientModule";
import module namespace console="http://exist-db.org/xquery/console";

declare namespace job="http://exist-db.org/apps/monex/job";
declare namespace jmx="http://exist-db.org/jmx";

(:declare variable $local:name := "history.state.gov";:)
(:declare variable $local:operation := "";:)
(:declare variable $local:app-root := "/db/apps/monex";:)
(:declare variable $local:data-root := "/db/apps/monex/data";:)

declare variable $local:name external;
declare variable $local:operation external;
declare variable $local:app-root external;
declare variable $local:data-root external;

declare variable $job:CHANNEL := "jmx.ping";

(:~
 : Check if mail module is available before importing the notification module.
 :)
declare function job:get-notification-method() as function(*) {
    let $tryImport :=
        try {
            util:import-module(xs:anyURI("http://exist-db.org/xquery/mail"), "mail", xs:anyURI("java:org.exist.xquery.modules.mail.MailModule")),
            true()
        } catch * {
            false()
        }
    return
        if ($tryImport) then
            function-lookup(xs:QName("notification:send-email"), 5)
        else
            job:notify-dummy#5
};

(:~
 :  Dummy notification function used if mail module is not available.
 :)
declare %private function job:notify-dummy($receiver as xs:string, $subject as xs:string, 
    $data as node()*, $settings as element(notifications), $attachment as xs:string?) {
    ()
};

declare %private function job:trim-whitespace($node) {
    typeswitch ($node)
        case element() return
            element { node-name($node) } {
                $node/@*,
                for $child in $node/node()
                return
                    job:trim-whitespace($child)
            }
        case text() return
            if (matches($node, "^\s+$")) then
                ()
            else
                $node
        default return
            $node
};

(:~
 : Check ping response and return status description.
 :)
declare function job:response($status as xs:string, $root as node()?, $elapsed as xs:duration?) {
    if ($root) then
        (: merge status into returned response :)
        let $root := job:trim-whitespace($root)
        return
            element { node-name($root) } {
                $root/@*,
                job:status($status, $elapsed),
                $root/*
            }
    else
        <jmx:jmx>
        { job:status($status, $elapsed) }
        </jmx:jmx>
};

(:~
 : Generate status description.
 :)
declare function job:status($status, $elapsed as xs:duration?) {
    <jmx:status>{$status}</jmx:status>,
    <jmx:instance>{$local:name}</jmx:instance>,
    <jmx:timestamp>{current-dateTime()}</jmx:timestamp>,
    if (exists($elapsed)) then
        <jmx:elapsed>{format-number(minutes-from-duration($elapsed), "00")}:{format-number(seconds-from-duration($elapsed), "00.000")}</jmx:elapsed>
    else    
        ()
};

declare function job:store-last-status($status as element()) {
    let $instance := $status/jmx:instance/string()
    return
        xmldb:store(job:get-instance-collection(), "state." || $instance || ".xml", $status)[2]
};

declare function job:store-data($data as element()) {
    xmldb:store(job:get-data-collection(), "jmx." || $local:name || "-" || format-time(current-time(), "[H00][m00][s00]") || ".xml", $data)
};

declare %private function job:get-instance-collection() {
    let $path := $local:data-root || "/" || $local:name
    return
        if (xmldb:collection-available($path)) then
            $path
        else
            xmldb:create-collection($local:data-root, $local:name)
};

declare %private function job:get-data-collection() {
    let $instance := job:get-instance-collection()
    let $name := format-date(current-date(), "[Y0000]-[M00]-[D00]")
    let $path := $instance || "/" || $name
    return
        if (xmldb:collection-available($path)) then
            $path
        else
            xmldb:create-collection($instance, $name)
};

(:~
 : Check if ping response is ok. If not, trigger notifications.
 :)
declare function job:check-response($instance as element(), $status as xs:string, $root as node()?, $elapsed as xs:duration?) {
    let $response := job:response($status, $root, $elapsed)
    let $error := $status != "ok" or $root/jmx:SanityReport/jmx:Status != "PING_OK"
    return (
        job:notify($error, $instance, $status, $response, ()),
        job:store-last-status($response),
        $response
    )
};

(:~
 : Send notifications to receivers (if status changed)
 :)
declare function job:notify($error as xs:boolean, $instance as element(), $status as xs:string, $response as element(),
    $attachment as xs:string?) {
    let $statusRoot := collection($config:data-root)/jmx:jmx[jmx:instance = $instance/@name]
    return
        if ((empty($statusRoot) and $error) or ($statusRoot/jmx:status != $response/jmx:status)) then
            let $notifications := doc($local:app-root || "/" || "notifications.xml")/*
        	for $receiver in $notifications/receiver[watching = $instance/@name or not(watching)]
            return
                job:get-notification-method()($receiver/@address, $status, $response, $notifications, $attachment)
        else
            ()
};

declare function job:ping($instance as element(instance)) as xs:boolean {
    let $start := util:system-time()
	let $url :=
        if ($local:operation and $local:operation != "") then
            $instance/@url || "/status?operation=" || $local:operation || "&amp;token=" || $instance/@token
        else
            $instance/@url || 
            "/status?c=instances&amp;c=processes&amp;c=locking&amp;c=memory&amp;c=caches&amp;c=system&amp;c=operatingsystem&amp;token=" ||
            $instance/@token
    let $request :=
        <http:request method="GET" href="{$url}" timeout="30"/>
    return
(:        try {:)
            let $response := http:send-request($request)
            return
                if ($response[1]/@status = "200") then (
                    if (empty($local:operation) or $local:operation = "") then
                        job:alerts($instance, $response[2]/*)
                    else
                        console:send($job:CHANNEL, job:check-response($instance, "ok", $response[2]/*, util:system-time() - $start)),
                    true()
                ) else (
                    console:send($job:CHANNEL, job:check-response($instance, $response[1]/@message/string(), (), util:system-time() - $start)),
                    false()
                )
(:        } catch * {:)
(:            console:send($job:CHANNEL, job:check-response($instance, $err:description, (), ())),:)
(:            false():)
(:        }:)
};

declare function job:alerts($instance as element(instance), $jmx as element(jmx:jmx)) {
    let $stored := job:store-data($jmx)
    for $alert in $instance/poll/alert
    let $alertTriggered := util:eval(
        "declare default element namespace 'http://exist-db.org/jmx';" ||
        $alert/@condition
    )
    return
        if ($alertTriggered) then
            let $status :=
                <jmx:jmx>
                { job:status($alert/@name/string(), ()) }
                </jmx:jmx>
            return
                job:notify(true(), $instance, "alert: " || $instance/@name, $status, serialize($jmx))
        else
            ()
};

if ($local:operation and $local:operation != "") then
    console:send($job:CHANNEL, job:response("pending", (), ()))
else
    (),
let $instances := collection($local:app-root)//instance
let $instance := $instances[@name = $local:name]
return
    job:ping($instance)