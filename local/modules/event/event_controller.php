<?php

use Symfony\Component\Yaml\Yaml;

/**
 * Event module class
 *
 * @package munkireport
 * @author AvB
 **/
class Event_controller extends Module_controller
{
    private $conf;

    public function __construct()
    {
        if (! $this->authorized()) {
            $out['items'] = array();
            $out['reload'] = true;
            $out['error'] = 'Session expired: please login';
            $obj = new View();
            $obj->view('json', array('msg' => $out));

            die();
        }
        // Add local config — point to vendor module's config.php since this file
        // is a local override of the controller only; views/config live in vendor.
        configAppendFile(APP_ROOT . 'vendor/munkireport/event/config.php', 'event');
        $this->module_path = APP_ROOT . 'vendor/munkireport/event/';

        try {
            $this->conf = Yaml::parseFile(conf('event')['config_path']);
        } catch (\Exception $e) {
           $this->conf = [];
        }
    }

    public function index()
    {
        echo "You've loaded the Event module!";
    }

    private function hasFilter()
    {
        return array_key_exists('filter', $this->conf) &&
            is_array($this->conf['filter']);
    }

    private function createFilter($query, $filter)
    {
      foreach ($filter as $module => $types) {
        if($types){
          $where[] = ['module', $module];
          foreach ($types as $type) {
            $where[] = ['type', '<>', $type];
          }
          $query->where(function($query) use ($where){
            $query->where($where);
          }, NULL, NULL, 'AND NOT'); // <- little hack to get NOT (Subquery)
        }
        else{
          $query->where('module', '<>', $module);
        }
      }

      return $query;
    }

    /**
     * Get Event
     *
     * Fix: use whereIn for type filter instead of orWhere, so that the
     * machine_group filter added by ->filter() is AND-ed with the full
     * type condition rather than only binding to the last OR clause due
     * to SQL operator precedence (AND before OR).
     *
     * @author AvB
     **/
    public function get($limit = 0)
    {
        $queryobj = Event_model::select(
                'event.serial_number', 'module', 'type', 'msg', 'data',
                'event.timestamp', 'machine.computer_name'
            )
            ->join('machine', 'machine.serial_number', '=', 'event.serial_number')
            ->whereIn('type', ['danger', 'info', 'success', 'warning'])
            ->filter()
            ->orderBy('event.timestamp', 'desc');
        if($limit){
            $queryobj->limit($limit);
        }
        if($this->hasFilter()){
          $this->createFilter($queryobj, $this->conf['filter']);
        }
        // dumpQuery($queryobj);
        $obj = new View();
        $obj->view('json', [
          'msg' => [
            'error' => '',
            'items' => $queryobj->get()->toArray(),
          ]
        ]);
    }
} // END class Event_controller
